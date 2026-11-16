# frozen_string_literal: true

require_relative "../lib/rakka"

# 障害は2層で扱う:
#   1. アクター単位: handle / apply_event の例外 → そのアクターの状態だけ捨てる
#   2. シャード単位: シャードRactor自体の異常終了 → Supervisorが作り直す
class UnstableCounter < Rakka::PersistentActor
  Increment = Data.define(:amount)
  Incremented = Data.define(:amount)
  CrashCommand = Data.define
  KillShard = Data.define

  # StandardErrorではない例外はシャードRactorごと落とす
  class Fatal < Exception; end # rubocop:disable Lint/InheritException

  def initial_state
    { count: 0 }
  end

  def increment(n) = send_command_sync(Increment[n])
  def crash! = send_command_sync(CrashCommand[])
  def kill_shard! = send_command_sync(KillShard[])
  def count = state[:count]

  def handle(cmd, _state)
    case cmd
    in Increment(amount:)
      [:persist, Incremented[amount]]
    in CrashCommand
      raise "Intentional crash!"
    in KillShard
      raise Fatal, "Intentional shard crash!"
    end
  end

  def apply_event(event, state)
    case event
    in Incremented(amount:)
      state.merge(count: state[:count] + amount)
    end
  end
end

system = Rakka::ActorSystem.new(
  event_store: Rakka::EventStore::Memory.new,
  shard_count: 1, # 2つのアクターが同じシャードに載ることを見せるため
  max_restarts: 3,
  within: 10
)

puts "=== Supervisor Demo ==="

a = UnstableCounter.new("a", system: system)
b = UnstableCounter.new("b", system: system)
a.increment(10)
b.increment(20)
puts "a=#{a.count} b=#{b.count} active=#{system.stats[:active_count]}"

puts "\n--- 1. Actor crash ---"
begin
  a.crash!
rescue Rakka::ActorCrashed => e
  puts "Caller got: #{e.message}"
end
puts "active=#{system.stats[:active_count]} (aだけ破棄、bは同じシャードで生存)"
puts "a=#{a.count} (イベントから復元) b=#{b.count}"

puts "\n--- 2. Shard crash ---"
begin
  a.kill_shard!
rescue Rakka::ShardUnavailable => e
  puts "Caller got: #{e.message}"
end
sleep 0.2
puts "restarts=#{system.stats[:restarts].inspect}"
puts "a=#{a.count} b=#{b.count} (新しいシャードRactor上で復元)"

a.increment(5)
puts "After increment(5): a=#{a.count}"

system.stop
puts "\nSystem stopped."
