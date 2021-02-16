# frozen_string_literal: true

require "optparse"

module Config
  class << self
    attr_accessor :scales, :concurrency

    def optparser
      return @optparser if defined?(@optparser)

      @optparser = OptionParser.new do |opts|
        opts.on("-n SCALES", "--number=SCALES", Array, "The total number of jobs to enqueue per tenant (comma-separated)") do |v|
          Config.scales = v.map(&:to_i).sort { -_1 }
        end

        opts.on("-c CONCURRENCY", "--concurrency=CONCURRENCY", Integer, "The concurrency factor (depends on implementation)") do |v|
          Config.concurrency = v
        end
      end
    end

    def parse!
      optparser.parse!

      puts "Config: #{self.inspect}"
    end

    def inspect
      {
        concurrency: concurrency,
        scales: scales
      }
    end
  end

  self.concurrency = 8
  self.scales = [300, 20, 500, 30, 200, 20]
end

require_relative "./raqueue"

class MailerWorker < Raqueue::Worker
  def perform(*)
    # Sleep for 200-250ms
    sleep(0.2 + rand(50) / 1000.0)
  end
end

class BatchMailerWorker < Raqueue::Worker
  def perform(payload)
    num = payload.delete(:total)
    num.times { MailerWorker.perform_async(payload.dup) }
  end
end

require_relative "./stats"
