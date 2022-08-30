# frozen_string_literal: true

require "bundler/inline"

gemfile(true, quiet: true) do
  source "https://rubygems.org"

  gem "ruby-next"
  gem "backports", require: false
end

require "ruby-next/language/runtime"
RubyNext::Language.watch_dirs << __dir__

using(Module.new do
  unless Warning.respond_to?(:[]=)
    refine Warning.singleton_class do
      def []=(k,v); end
    end
  end
end)

require "backports/ractor/ractor" unless defined?(Ractor)

Warning[:experimental] = false

require "optparse"

module Config
  class << self
    attr_accessor :scales, :concurrency, :head_size, :stats_reset_interval

    def optparser
      return @optparser if defined?(@optparser)

      @optparser = OptionParser.new do |opts|
        opts.on("-n SCALES", "--number=SCALES", Array, "The total number of jobs to enqueue per tenant (comma-separated)") do |v|
          Config.scales = v.map do
            _1.split("|").map(&:to_i)
          end
        end

        opts.on("-c CONCURRENCY", "--concurrency=CONCURRENCY", Integer, "The concurrency factor (depends on implementation)") do
          Config.concurrency = _1
        end

        opts.on("--head=HEAD", Integer, "The head size for fairness metrics") do
          Config.head_size = _1
        end

        opts.on("--stats-reset-interval=INTERVAL", Integer, "The number of seconds of no enqueued jobs to create a new head for a tenant") do
          Config.stats_reset_interval = _1
        end
      end
    end

    def parse!
      optparser.parse!

      puts "Config: #{self.inspect}"
    end

    def each_tenant_config
      scales.each.with_index do |scale, i|
        scale = Array(scale)

        scale.each_slice(2) do |(size, delay)|
          yield i, size, delay
        end
      end
    end

    def inspect
      {
        concurrency:,
        scales:,
        head_size:,
        stats_reset_interval:
      }
    end
  end

  self.concurrency = 12
  self.scales = [300, 20, 500, 30, 200, 20]
  self.head_size = 20
  self.stats_reset_interval = 10
end

require_relative "./raqueue"

class MailerWorker < Raqueue::Worker
  def perform(*args)
    # Sleep for 200-250ms
    sleep(0.2 + rand(50) / 1000.0)
  end
end

require_relative "./stats"
