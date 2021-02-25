# frozen_string_literal: true

begin
  require "tty-cursor"
  require "tty-screen"
  require "tty-table"
  require "pastel"
rescue LoadError
  require "bundler/inline"

  gemfile(true, quiet: true) do
    source "https://rubygems.org"

    gem "tty-cursor"
    gem "tty-screen"
    gem "tty-table"
    gem "pastel"
  end
end

# Pastel is not Ractor-ready,
# so let's just extract the required data to our custom constant
AVAILABLE_COLORS = Pastel.new.styles.filter_map do |name, val|
  next if val < 31

  next if name.to_s.start_with?("on_")

  val
end

Ractor.make_shareable(AVAILABLE_COLORS)

TENANT_NAMES = ("a".."z").reverse_each.take(AVAILABLE_COLORS.size + 2)
# Let's leave only 'v' :)
TENANT_NAMES.delete("w")
TENANT_NAMES.delete("u")
Ractor.make_shareable(TENANT_NAMES)

# Receive statistics from the Raqueue in the real-time and draw some stuff in the terminal
module Stats
  class << self
    def receiver(refresh_interval: 1)
      Ractor.new(refresh_interval) do |refresh_interval|
        prev_frame = Time.now
        data = []
        refresh_lines = -1

        loop do
          msg = Ractor.receive

          if msg == :result
            Stats.draw_workers(data, refresh_lines: refresh_lines)
            break Ractor.yield(data, move: true)
          elsif msg == :total
            next Ractor.yield(data.size)
          end

          data << msg

          if Time.now - prev_frame > refresh_interval
            refresh_lines = Stats.draw_workers(data, refresh_lines: refresh_lines)
            prev_frame = Time.now
          end
        end
      end
    end

    def fetch_total(stats)
      stats << :total
      stats.take
    end

    using(Module.new do
      refine String do
        def color(code)
          "\e[#{code}m#{self}\e[0m"
        end
      end
    end)

    # Data has a form of [ [queue:0, worker_index:1, end_time:2, start_time:3, tenant:4] ]
    def draw_workers(data, refresh_lines: -1)
      lines = Hash.new { |h, k| h[k] = [] }

      data.each do |item|
        color = AVAILABLE_COLORS[item[4]]
        name = TENANT_NAMES[item[4]]
        worker_id = "#{item[0]}:#{item[1]}"
        lines[worker_id] ||= []
        lines[worker_id] << name.color(color)
      end

      max_width = TTY::Screen.columns

      print TTY::Cursor.clear_lines(refresh_lines + 1, :up) if refresh_lines > 0
      lines.each_value do |line|
        next unless line
        size = line.size
        if size > max_width
          offset = 3 + (size - max_width)
          puts "...#{line[offset..].join}"
        else
          puts line.join
        end
      end

      lines.size
    end

    using(Module.new do
      refine Array do
        def sorted
          @sorted ||= sort
        end

        def mean
          @mean ||= (sum.to_f / size)
        end

        # Requires sorted array
        def p90
          @p90 ||= sorted[(0.9*size).to_i]
        end

        def stddev
          from = mean
          Math.sqrt(sum { (_1 - from)**2 } / size)
        end
      end

      refine Float do
        def duration
          t = self
          format("%02d.%03d", t % 60, t.modulo(1) * 1000)
        end
      end
    end)

    def draw_table(data)
      tenants = Hash.new { |h, k| h[k] = [] }

      all_lats = []
      min_start = nil
      max_end = nil

      data.each do |item|
        lat = item[2] - item[3]

        min_start = item[3] if min_start.nil? || item[3] < min_start
        max_end = item[2] if max_end.nil? || item[2] > max_end

        # Do not track batch jobs
        all_lats << lat unless tenants[item[4]].empty?

        tenants[item[4]] << lat
      end

      # Remove batch jobs
      tenants.transform_values! { _1.shift; _1 }

      all_mean = all_lats.mean
      head = tenants.values.map(&:size).min

      cols = TTY::Screen.columns > 120 ? 6 : 4

      table = TTY::Table.new(header: ["", "Total", "Lat first-#{head} (mean)", "Lat first-#{head} (p90)", "Lat (mean)", "Lat (p90)"].take(cols))

      tenants.each do |k, lats|
        color = AVAILABLE_COLORS[k]
        table << [
          "Tenant #{TENANT_NAMES[k]}",
          lats.size,
          lats.take(head).mean.duration,
          lats.take(head).p90.duration,
          lats.mean.duration,
          lats.p90.duration,
        ].map { _1.to_s.color(color) }.take(cols)
      end

      table << [
        "Overall",
        "#{data.size} (in #{(max_end - min_start).duration}s)",
        "",
        "",
        all_mean.duration,
        all_lats.p90.duration
      ].take(cols)

      table << [
        "Stddev",
        "",
        tenants.values.map { _1.take(head).mean }.stddev,
        tenants.values.map { _1.take(head).p90 }.stddev,
        tenants.values.map(&:mean).stddev,
        tenants.values.map(&:p90).stddev
      ].take(cols)

      rendered = table.render(:unicode, padding: [0, 2]) do |renderer|
        renderer.border.separator = [0, tenants.size, tenants.size + 1]
      end

      puts rendered
    end
  end
end
