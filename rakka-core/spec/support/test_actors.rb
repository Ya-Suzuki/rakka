# frozen_string_literal: true

class Counter < Rakka::PersistentActor
  Increment = Data.define(:amount)
  IncrementTwice = Data.define(:amount)
  Crash = Data.define
  KillShard = Data.define
  Sleep = Data.define(:seconds)
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
