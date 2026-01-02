# frozen_string_literal: true

require_relative "../lib/rakka"

# クラッシュする可能性のあるActor
class UnstableCounter < Rakka::PersistentActor
  Increment = Data.define(:amount)
  Incremented = Data.define(:amount)
  CrashCommand = Data.define

  def initial_state
    { count: 0 }
  end

  def increment(n)
    send_command_sync(Increment[n])
  end

  def crash!
    send_command_sync(CrashCommand[])
  end

  def count
    state[:count]
  end

  def handle(cmd, state)
    case cmd
    in Increment(amount:)
      [:persist, Incremented[amount]]
    in CrashCommand
      raise "Intentional crash!"
    end
  end

  def apply_event(event, state)
    case event
    in Incremented(amount:)
      state.merge(count: state[:count] + amount)
    end
  end
end

Rakka.configure { |c| c.event_store = Rakka::EventStore::Memory.new }

puts "=== Supervisor Demo ==="

supervisor = Rakka::Supervisor.new(
  strategy: :one_for_one,
  max_restarts: 3,
  within: 10
).start

# Actorを監視下に置く
counter = supervisor.supervise(UnstableCounter, "counter-1")
puts "Created counter, count: #{counter.count}"

counter.increment(10)
puts "After increment(10): #{counter.count}"

puts "\nChildren: #{supervisor.children.inspect}"

puts "\n--- Triggering crash ---"
Thread.new do
  begin
    counter.crash!
  rescue => e
    # クラッシュはRactor内で発生
  end
end

# 少し待ってリスタートを確認
sleep 1.5

puts "\nChildren after crash: #{supervisor.children.inspect}"

# 新しいActorを取得（イベントから復元されている）
new_counter = supervisor.supervise(UnstableCounter, "counter-1")
puts "Restarted counter count: #{new_counter.count}"

new_counter.increment(5)
puts "After increment(5): #{new_counter.count}"

puts "\n--- Multiple crashes to hit limit ---"
3.times do |i|
  puts "Crash #{i + 1}..."
  Thread.new do
    begin
      c = supervisor.supervise(UnstableCounter, "counter-1")
      c.crash!
    rescue
    end
  end
  sleep 1
end

sleep 1.5
puts "\nFinal children: #{supervisor.children.inspect}"

supervisor.stop
puts "\nSupervisor stopped."
