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

total_jobs = 0

Config.each_tenant_config do |tenant, batch_size, delay|
  total_jobs += (batch_size + 1)

  if delay
    BatchMailerWorker.perform_at(Time.now + delay, {total: batch_size, tenant:})
  else
    BatchMailerWorker.perform_async({total: batch_size, tenant:})
  end
  sleep 1
end

node.wait_till_executed(total_jobs)
