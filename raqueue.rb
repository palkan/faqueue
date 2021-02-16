# frozen_string_literal: true

# Raqueue is a background jobs executor using Ractors.
# It has a very basic interface and only assumed to be used for demonstration purposes.

module Raqueue
  class << self
    attr_accessor :node
  end

  module Utils
    module_function

    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end

  class Pipe
    def initialize
      @ractor = Ractor.new do
        loop do
          Ractor.yield(Ractor.receive, move: true)
        end
      end
    end

    def enqueue_job(job)
      ractor.send(job)
    end

    def enqueue(queue, worker, payload)
      ractor.send({queue: queue, worker_class: worker, payload: payload})
    end

    def dequeue
      ractor.take
    end

    private

    attr_reader :ractor
  end

  class Node
    def initialize
      @stats = Stats.receiver
      @queues = {}
      @pipe = Pipe.new
    end

    def queue(name, size)
      raise ArgumentError, "Queue already registered: #{name}" if queues.key?(name)

      queues[name] = {name: name, size: size}
    end

    def enqueue(queue, worker, payload)
      pipe.enqueue(queue, worker, payload)
    end

    def start
      @executor = Ractor.new(stats, queues, pipe) do |stats, queues, pipe|
        start_time = Time.now

        queues.values.each do |config|
          queues[config[:name]] = Queue.start(**config, stats: stats, node: pipe)
        end

        loop do
          job = pipe.dequeue

          if job == :stop
            queues.each_value.map do |queue|
              queue.wait_till_executed
            end

            stats << :result

            # tty-table is not Ractor-ready,
            # so we need to pop this data up to the main Ractor
            data = stats.take
            Ractor.yield data
            break
          end

          queue = job.delete(:queue)
          queues.fetch(queue).pipe.send(job)
        end
      end
    end

    def wait_till_executed(num)
      loop do
        executed = Stats.fetch_total(stats)
        break if executed >= num

        sleep 1
      end

      pipe.enqueue_job :stop
      stats = executor.take
      Stats.draw_table(stats)
    end

    private

    attr_reader :stats, :start_time, :queues, :executor, :pipe
  end

  class Queue
    class << self
      def start(**kwargs)
        new(**kwargs).start
      end
    end

    attr_reader :name, :size, :pipe

    def initialize(name: :default, size:, stats: nil, node:)
      @name = name
      @size = size
      @stats = stats
      @node = node

      @pipe = Ractor.new do
        loop do
          Ractor.yield(Ractor.receive, move: true)
        end
      end
    end

    def start
      @workers = size.times.map do |num|
        Ractor.new(pipe, stats, num, name, node, name: "#{inspect} ##{num}") do |pipe, stats, num, queue, node|
          Ractor.current[:node] = node
          Ractor.current[:worker_id] = num
          Ractor.current[:stats] = stats

          loop do
            job = pipe.take

            next unless job

            next Ractor.yield(:stopping) if job == :stop

            begin
              worker = Object.const_get(job[:worker_class])

              worker.new.run(job[:payload])
            rescue Exception => e
              warn "Failed to execute job #{job}: #{e.message}"
            end
          end
        rescue Ractor::ClosedError
          nil
        end
      end

      self
    end

    def wait_till_executed
      pipe << :stop

      r, val = Ractor.select(*workers)
      raise "Unexpected shutdown response: #{val} from #{r}" unless val == :stopping

      pipe.close_outgoing

      while workers.any?
        r, _ = Ractor.select(*workers)
        workers.delete(r)
      end
    end

    def inspect
      "🦀 #{self.class.name}[#{name}] 🦀"
    end

    private

    attr_reader :stats, :workers, :node
  end

  class Worker
    class << self
      def perform_async(payload = {}, queue: :default)
        node = Ractor.current[:node] || Raqueue.node
        payload[:start] ||= Utils.now
        payload[:queue] = queue
        node.enqueue queue, self.name, payload
      end
    end

    def run(payload)
      before_perform(payload)
      perform(payload)
    end

    def perform(payload = {})
    end

    def before_perform(payload = {})
      stats = Ractor.current[:stats]
      stats.send([
        payload[:queue],
        Ractor.current[:worker_id],
        Utils.now,
        payload[:start],
        payload[:tenant]
      ], move: true) if stats
    end
  end
end
