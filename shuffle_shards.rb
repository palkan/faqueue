# frozen_string_literal: true

require_relative "./app"

module Config
  class << self
    attr_accessor :shards

    def inspect
      {
        concurrency: concurrency,
        scales: scales,
        shards: shards
      }
    end
  end
end

Config.shards = 2

Config.optparser.banner = "Shuffle shard: choose a bulk queue randomly"
Config.optparser.on("-s SHARDS", "--shards SHARDS", Integer, "The number of shards") do |val|
  Config.shards = val
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

Config.scales.each.with_index do |num, i|
  BatchMailerWorker.perform_async({total: num, tenant: i, shard: SHARDS.sample}, queue: :default)
  sleep 1
end

node.wait_till_executed(Config.scales.sum + Config.scales.size)
