# frozen_string_literal: true

require_relative "./app"

Config.optparser.banner = "Baseline: just a queue, totally unfair"
Config.parse!

node = Raqueue.node = Raqueue::Node.new
node.queue(:default, Config.concurrency)
node.start

Config.scales.each.with_index do |num, i|
  BatchMailerWorker.perform_async({total: num, tenant: i})
  sleep 1
end

node.wait_till_executed(Config.scales.sum + Config.scales.size)
