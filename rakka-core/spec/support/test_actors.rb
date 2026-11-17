# frozen_string_literal: true

class Counter < Rakka::PersistentActor
  Increment = Data.define(:amount)
  IncrementTwice = Data.define(:amount)
  Crash = Data.define
  KillShard = Data.define
  Sleep = Data.define(:seconds)
  SleepThenKillShard = Data.define(:seconds)
  SlowIncrement = Data.define(:amount, :seconds)
  Forward = Data.define(:target_id, :amount)
  ForwardThenCrash = Data.define(:target_id, :amount)
  AskInside = Data.define(:target_id)
  Incremented = Data.define(:amount)

  # StandardErrorではないので、アクターではなくシャードRactorごと落とす
  class Fatal < Exception; end # rubocop:disable Lint/InheritException

  def initial_state
    { count: 0 }
  end

  def increment(amount = 1) = send_command_sync(Increment[amount])
  def increment_twice(amount) = send_command_sync(IncrementTwice[amount])
  def increment_async(amount = 1) = send_command(Increment[amount])
  def sleep_async(seconds) = send_command(Sleep[seconds])
  def sleep_then_kill_shard_async(seconds) = send_command(SleepThenKillShard[seconds])
  def slow_increment_async(amount, seconds) = send_command(SlowIncrement[amount, seconds])
  def forward(target_id, amount) = send_command_sync(Forward[target_id, amount])
  def forward_then_crash(target_id, amount) = send_command_sync(ForwardThenCrash[target_id, amount])
  def ask_inside(target_id) = send_command_sync(AskInside[target_id])
  def crash! = send_command_sync(Crash[])
  def kill_shard! = send_command_sync(KillShard[])
  def count = state[:count]

  def handle(command, _state)
    case command
    in Increment(amount:) if amount.zero?
      [:noop]
    in Increment(amount:)
      [:persist, Incremented[amount]]
    in IncrementTwice(amount:)
      [:persist, Incremented[amount], Incremented[amount]]
    in Sleep(seconds:)
      sleep seconds
      [:noop]
    in SleepThenKillShard(seconds:)
      sleep seconds
      raise Fatal, "shard down"
    in SlowIncrement(amount:, seconds:)
      sleep seconds
      [:persist, Incremented[amount]]
    in Forward(target_id:, amount:)
      Counter.new(target_id).increment_async(amount)
      [:persist, Incremented[amount]]
    in ForwardThenCrash(target_id:, amount:)
      Counter.new(target_id).increment_async(amount)
      raise "boom after send"
    in AskInside(target_id:)
      Counter.new(target_id).count
      [:noop]
    in Crash
      raise "boom"
    in KillShard
      raise Fatal, "shard down"
    end
  end

  def apply_event(event, state)
    case event
    in Incremented(amount:)
      state.merge(count: state[:count] + amount)
    end
  end
end

# クラスごとのスナップショット設定の確認用
class FrequentCounter < Counter
  snapshot_every 2
end

class NoSnapshotCounter < Counter
  snapshot_every nil
end

class MigratedCounter < Counter
  snapshot_schema 2
end

# 上限つきカウンタ。競合時にコマンドが最新状態で判定し直されることの確認用
class LimitedCounter < Rakka::PersistentActor
  Increment = Data.define(:amount)
  Incremented = Data.define(:amount)
  LIMIT = 10

  def initial_state = { count: 0 }
  def increment(amount) = send_command_sync(Increment[amount])
  def count = state[:count]

  def handle(command, state)
    case command
    in Increment(amount:) if state[:count] + amount > LIMIT
      [:reject, :limit_exceeded]
    in Increment(amount:)
      [:persist, Incremented[amount]]
    end
  end

  def apply_event(event, state)
    case event
    in Incremented(amount:)
      state.merge(count: state[:count] + amount)
    end
  end
end
