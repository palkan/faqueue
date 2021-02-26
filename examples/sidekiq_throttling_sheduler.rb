# frozen_string_literal: true

# Add simple throttling functionality to
# Sidekiq workers ("perform one job in N seconds").
#
# It's possible to distinguish jobs and throttle separately
# (by using separate latches depending on job's args)
#
# Example:
#
#   class MailerJob
#     include Sidekiq::Worker
#     include Sidekiq::ThrottlingScheduler
#
#     throttle do
#       period 0.1.seconds
#
#       latch_id { |account_id, *| "mail:#{account_id}" }
#
#       metrics 'mail'
#     end
#
#     def perform(account_id, *)
#       # No changes required to the perform method
#     end
#   end
#
module Sidekiq
  module ThrottlingScheduler
    # Prefix for latches
    REDIS_PREFIX = "throttler:v1:"

    class << self
      # Track scheduling metrics (see NewRelicInstrumenter example below).
      # Could be any callable that accepts (metrics_name, delay).
      attr_accessor :intrumenter

      # Remove all latches
      def reset_all
        Sidekiq.redis do |redis|
          keys = redis.keys("#{REDIS_PREFIX}*")
          redis.del(*keys) unless keys.empty?
        end
      end
    end

    # This is an intermediate worker which "intercepts"
    # the throttled jobs and "decide" whether to enqueue them right away
    # or schedule in the future
    class Worker
      include Sidekiq::Worker
      # Don't forget to add "throttler" queue to Sidekiq config
      # with high priority (throttler jobs are fast)
      sidekiq_options queue: :throttler

      def perform(klass_name, *args)
        klass = klass_name.constantize

        klass.throttle_resolver.perform(*args)
      end
    end

    # Helper object that quacks like Worker and
    # contains info about actual class
    class Wrapper
      def initialize(klass)
        @klass = klass
      end

      def perform_async(*args)
        Worker.perform_async(@klass, *args)
      end
    end

    # Push delay info to New Relic.
    # Enable it via:
    #
    #   Sidekiq::ThrottlingScheduler.instrumenter = Sidekiq::ThrottlingScheduler::NewRelicInstrumenter
    module NewRelicInstrumenter
      PREFIX = 'Custom/Sidekiq/Throttled/'

      def self.call(metric_name, delay)
        ::NewRelic::Agent.record_metric(
          "#{PREFIX}#{metric_name}/queue_delay",
          delay
        )
      end
    end

    class Resolver
      attr_reader :throttle_period, :latch_id_generator, :job_class, :metrics_name

      def initialize(klass)
        @job_class = klass
        @latch_id_generator = proc { klass.name }
      end

      def perform(*args)
        latch = job_latch(*args)

        Sidekiq.redis do |redis|
          now = Time.now.to_f
          deadline = redis.get(latch)&.to_f

          if deadline && (now < deadline + throttle_period)
            redis.multi do
              deadline += throttle_period
              delay = deadline - now
              ThrottlingScheduler.instrumenter&.call(metrics_name, delay) if metrics_configured?
              @job_class.perform_in(delay, *args)
              redis.set latch, deadline
            end
          else
            redis.multi do
              @job_class.perform_async(*args)
              redis.set latch, now
            end
          end
        end
      end

      def period(val)
        @throttle_period = val
      end

      def latch_id(&block)
        @latch_id_generator = block
      end

      def metrics(val)
        @metrics_name = val
      end

      # Make sure that all required parameters are set
      def validate!
        raise "Missing period" if throttle_period.nil?
      end

      private

      def metrics_configured?
        !@metrics_name.nil?
      end

      def job_latch(*args)
        "#{REDIS_PREFIX}:#{latch_id_generator.call(args)}"
      end
    end

    # Sidekiq worker extension
    module DSL
      attr_reader :throttle_resolver

      def throttle(&block)
        @throttle_resolver = Resolver.new(self).tap do |resolver|
          resolver.instance_eval(&block)
          resolver.validate!
        end
      end

      def throttled
        return @wrapper if instance_variable_defined?(:@wrapper)
        @wrapper = Wrapper.new(self)
      end

      def inherited(subclass)
        resolver = throttle_resolver

        subclass.throttle do
          period resolver.throttle_period
          latch_id(&resolver.latch_id_generator)
          metrics(resolver.metrics_name)
        end

        super
      end
    end
  end
end
