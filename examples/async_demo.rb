# frozen_string_literal: true

require_relative "../lib/rakka"

class Counter < Rakka::PersistentActor
  Increment = Data.define(:amount)
  Incremented = Data.define(:amount)

  def initial_state
    { count: 0 }
  end

  def increment(n)
    send_command(Increment[n])  # 非同期
  end

  def increment_sync(n)
    send_command_sync(Increment[n])  # 同期
  end

  def count
    state[:count]
  end

  def handle(cmd, state)
    case cmd
    in Increment(amount:)
      [:persist, Incremented[amount]]
    end
  end

  def apply_event(event, state)
    sleep 0.05  # 重い処理をシミュレート
    case event
    in Incremented(amount:)
      state.merge(count: state[:count] + amount)
    end
  end
end

Rakka.configure { |c| c.event_store = Rakka::EventStore::Memory.new }

# イベントハンドラを登録（非同期でも呼ばれる！）
events_received = []
Rakka.subscribe(Counter::Incremented) do |event, metadata|
  events_received << event
  puts "[Handler] Incremented by #{event.amount} (async)"
end

counter = Counter.new("async-test")

puts "=== 非同期テスト ==="
puts "Initial count: #{counter.count}"

# 非同期で3回送る
counter.increment(1)
counter.increment(2)
counter.increment(3)

puts "Immediately after sends (not checking state yet)"

# 変更が反映されるまでループで待つ
expected = 6
start = Time.now
loop do
  current = counter.count
  if current == expected
    elapsed = ((Time.now - start) * 1000).round(2)
    puts "Reached #{expected} after #{elapsed}ms"
    break
  end
  if Time.now - start > 1
    puts "Timeout! count=#{current}"
    break
  end
  sleep 0.001
end

puts "\nEvents received by handler: #{events_received.size}"

puts "\n=== 同期テスト ==="
counter2 = Counter.new("sync-test")
puts "Initial count: #{counter2.count}"

counter2.increment_sync(1)
puts "After sync increment(1): #{counter2.count}"

counter2.increment_sync(2)
puts "After sync increment(2): #{counter2.count}"

counter2.increment_sync(3)
puts "After sync increment(3): #{counter2.count}"

puts "\nTotal events received: #{events_received.size}"
