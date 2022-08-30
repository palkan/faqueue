# frozen_string_literal: true

# Ractor-compatible in-memory cache
class RCache
  Ractor = Backports::Ractor unless defined?(Ractor)

  def initialize
    @storage = Ractor.new do
      store = {}

      loop do
        sender, id, *cmd = Ractor.receive

        case cmd
          in :get, key
            sender << [id, store[key]]
          in :set, key, val
            store[key] = val
            sender << [id, val]
          in :incr, key
            store[key] ||= 0
            store[key] += 1
            sender << [id, store[key]]
          in :decr, key
            if store[key] && store[key] > 0
              store[key] -= 1
            else
              store[key]
            end
            sender << [id, store[key]]
        end
      end
    end
  end

  def incr(key)
    id = current_id
    storage.send([Ractor.current, id, :incr, key])
    Ractor.receive_if { _1[0] == id }[1]
  end

  def decr(key)
    id = current_id
    storage.send([Ractor.current, id, :decr, key])
    Ractor.receive_if { _1[0] == id }[1]
  end

  def get(key)
    id = current_id
    storage.send([Ractor.current, id, :get, key])
    Ractor.receive_if { _1[0] == id }[1]
  end

  def set(key, val)
    id = current_id
    storage.send([Ractor.current, id, :set, key, val])
    Ractor.receive_if { _1[0] == id }[1]
  end

  private

  attr_reader :storage

  def current_id
    Ractor.current.inspect.match(/Ractor:#(\d+)/)[1]
  end
end

if ARGV[0] == "test"
  CACHE = RCache.new

  Ractor.make_shareable(CACHE)

  r1 = Ractor.new do
    CACHE.set("test", "1")
  end

  r2 = Ractor.new do
    CACHE.set("test", "2")
  end

  r3 = Ractor.new(r1, r2) do |r1, r2|
    Ractor.select(r1, r2)

    Ractor.yield CACHE.get("test")
  end

  p r3.take
end
