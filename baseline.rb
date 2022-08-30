# frozen_string_literal: true

require_relative "./app"

Config.optparser.banner = "Baseline: just a queue, totally unfair"
Config.parse!

node = Raqueue.node = Raqueue::Node.new
node.queue(:default, Config.concurrency)
node.start

class BatchMailerWorker < Raqueue::Worker
  def perform(payload)
    num = payload.delete(:total)
    num.times { MailerWorker.perform_async(payload.dup, queue: :default) }
  end
end

total_jobs = 0

Config.each_tenant_config do |tenant, batch_size, delay|
  total_jobs += (batch_size + 1)

  if delay
    BatchMailerWorker.perform_at(Time.now + delay, {total: batch_size, tenant:}, queue: :default)
  else
    BatchMailerWorker.perform_async({total: batch_size, tenant:}, queue: :default)
  end

  sleep 1
end

node.wait_till_executed(total_jobs)
