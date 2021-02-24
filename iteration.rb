# frozen_string_literal: true

require_relative "./app"

module Config
  class << self
    attr_accessor :max_time

    def inspect
      {
        concurrency: concurrency,
        scales: scales,
        max_time: max_time
      }
    end
  end
end

Config.max_time = 2

Config.optparser.on("-t TIME", "--time=TIME", Integer, "The maximum time to perform iterations (seconds)") do |v|
  Config.max_time = v
end

Config.optparser.banner = "Iterruptible iteration: perform jobs within a bulk job in a loop, re-enqueue if hits time limit"
Config.parse!

module Iteration
  def perform(payload)
    cursor = payload.fetch(:cursor, 0)
    total = payload.fetch(:total)
    max_time = payload.fetch(:max_time)

    total -= cursor

    return if total <= 0

    start = Time.now

    total.times do
      each_iteration(payload.dup)
      cursor += 1

      break if (Time.now - start) > max_time
    end

    self.class.perform_async(payload.merge(cursor: cursor))
  end
end


node = Raqueue.node = Raqueue::Node.new
node.queue(:default, Config.concurrency)
node.start

class BatchMailerWorker < Raqueue::Worker
  prepend Iteration

  def each_iteration(payload)
    MailerWorker.new.run(payload)
  end
end

Config.scales.each.with_index do |num, i|
  BatchMailerWorker.perform_async({total: num, tenant: i, max_time: Config.max_time})
  sleep 1
end

node.wait_till_executed(Config.scales.sum + Config.scales.size)
