# frozen_string_literal: true

require_relative "./app"
require_relative "./rcache"

Config.optparser.banner = "Throttling + Scheduling: during perform, re-enqueue the job with delay if the rate is too high"
Config.parse!

CACHE = RCache.new
Ractor.make_shareable(CACHE)

module Throttler
  def run(payload)
    return super if payload[:skip_throttle] == true

    now = Time.now.to_f
    latch = payload[:tenant]
    deadline = cache.get(latch)&.to_f
    throttle_period = payload[:throttle] || 0.2
    payload[:skip_throttle] = true

    if deadline && (now < deadline + throttle_period)
      deadline += throttle_period
      self.class.perform_at(Time.at(deadline), payload, queue: :default)
      cache.set latch, deadline
    else
      self.class.perform_async(payload, queue: :default)
      cache.set latch, now
    end
  end

  private

  def cache
    CACHE
  end
end

MailerWorker.prepend(Throttler)

node = Raqueue.node = Raqueue::Node.new
node.queue(:default, Config.concurrency)
node.queue(:throttler, 4)
node.start

class BatchMailerWorker < Raqueue::Worker
  def perform(payload)
    num = payload.delete(:total)

    num.times { MailerWorker.perform_async(payload.dup, queue: :throttler) }
  end
end

Config.scales.each.with_index do |num, i|
  BatchMailerWorker.perform_async({total: num, tenant: i})
  sleep 1
end

node.wait_till_executed(Config.scales.sum + Config.scales.size)
