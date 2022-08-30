# frozen_string_literal: true

require_relative "./app"
require_relative "./rcache"

module Config
  class << self
    attr_accessor :credits
    attr_writer :weights

    def weights
      return @weights if @weights

      fast = Integer(concurrency * 0.66)
      slow = [1, Integer(concurrency * 0.15)].max
      medium = concurrency - fast - slow

      @weights = [fast, medium, slow]
    end

    def inspect
      {
        concurrency:,
        scales:,
        weights:,
        credits:,
        head_size:,
        stats_reset_interval:
      }
    end
  end
end

Config.credits = Config.head_size

Config.optparser.banner = "Balanced shards: assigning a queue (fast, medium, slow) to a job depending on the tenant's usage"
Config.optparser.on("--weights=WEIGHTS", Array, "Weights (concurrency) for queuss (fast-medium-slow)") do
  Config.weights = _1.map(&:to_i)
end
Config.optparser.on("--credits=CREDITS", Integer, "Initial credits (the number of jobs to perform via fast queue)") do
  Config.credits = _1
end

Config.parse!

node = Raqueue.node = Raqueue::Node.new
node.queue(:default, 2)
node.queue(:fast, Config.weights.shift)
node.queue(:medium, Config.weights.shift)
node.queue(:slow, Config.weights.shift)

node.start

CACHE = RCache.new
Ractor.make_shareable(CACHE)

class BatchMailerWorker < Raqueue::Worker
  def perform(payload)
    num = payload.delete(:total)
    tenant = payload.fetch(:tenant)
    med_threshold = payload.delete(:medium_threshold)

    num.times do
      queue = select_queue(tenant, med_threshold)
      MailerWorker.perform_async(payload.dup, queue: queue)
    end
  end

  private

  def select_queue(tenant, medium_threshold)
    credits = cache.decr(tenant)

    if credits.nil? || credits <= 0
      :slow
    elsif credits < medium_threshold
      :medium
    else
      :fast
    end
  end

  def cache
    CACHE
  end
end

total_jobs = 0

Config.each_tenant_config do |tenant, batch_size, delay|
  total_jobs += (batch_size + 1)

  # Populate initial credits
  CACHE.set(tenant, Config.credits + 1)

  medium_threshold = Config.credits / 2

  if delay
    BatchMailerWorker.perform_at(Time.now + delay, {total: batch_size, tenant:, medium_threshold:}, queue: :default)
  else
    BatchMailerWorker.perform_async({total: batch_size, tenant:, medium_threshold:}, queue: :default)
  end

  sleep 1
end

# Re-fill credits every stats reset interval
Thread.new do
  sleep Config.stats_reset_interval

  max = Config.credits
  refill = max / 2

  Config.each_tenant_config do |tenant|
    current = CACHE.get(tenant)

    CACHE.set(tenant, [max, current + refill].min) if current < max
  end
end

node.wait_till_executed(total_jobs)
