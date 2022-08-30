# frozen_string_literal: true

require_relative "./app"

module Config
  class << self
    attr_accessor :shards, :shard_to_scale

    def inspect
      {
        concurrency:,
        scales:,
        shards:,
        shard_to_scale:,
        head_size:,
        stats_reset_interval:
      }
    end
  end
end

Config.shards = 4
Config.shard_to_scale = [0, 1, 2, 1, 3, 1]

Config.optparser.banner = "Predefined shards: assigning a specific shard to each tenant"
Config.optparser.on("-s SHARDS", "--shards SHARDS", Integer, "The number of shards") do |val|
  Config.shards = val
end
Config.optparser.on("-m MAPPING", "--mapping=MAPPING", Array, "Tenant to shard mapping (e.g., '0,1,2,1,0')") do |v|
  Config.shard_to_scale = v.map(&:to_i)
end

Config.parse!

node = Raqueue.node = Raqueue::Node.new
node.queue(:default, 2)

SHARDS = ("a".."z").take(Config.shards).map(&:to_sym).freeze

SHARDS.each do |shard_name|
  node.queue(shard_name, Config.concurrency / Config.shards)
end

node.start

class BatchMailerWorker < Raqueue::Worker
  def perform(payload)
    num = payload.delete(:total)
    queue = payload.delete(:shard)
    num.times { MailerWorker.perform_async(payload.dup, queue: queue) }
  end
end

total_jobs = 0

Config.each_tenant_config do |tenant, batch_size, delay|
  total_jobs += (batch_size + 1)

  if delay
    BatchMailerWorker.perform_at(Time.now + delay, {total: batch_size, tenant:,  shard: SHARDS[Config.shard_to_scale[tenant]]}, queue: :default)
  else
    BatchMailerWorker.perform_async({total: batch_size, tenant:,  shard: SHARDS[Config.shard_to_scale[tenant]]}, queue: :default)
  end

  sleep 1
end

node.wait_till_executed(total_jobs)
