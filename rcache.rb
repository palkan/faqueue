# frozen_string_literal: true

# Ractor-compatible in-memory cache
class RCache
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
        end
      end
    end
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
