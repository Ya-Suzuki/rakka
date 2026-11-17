# frozen_string_literal: true

# アクター間メッセージング: 口座から口座への送金。
# 出金側の handle が入金側のアクターにコマンドを送る。

require_relative "../lib/rakka"

class Account < Rakka::PersistentActor
  Deposit = Data.define(:amount)
  Transfer = Data.define(:to, :amount)

  MoneyDeposited = Data.define(:amount)
  MoneyTransferred = Data.define(:to, :amount)

  def initial_state = { balance: 0 }

  def deposit(amount) = send_command_sync(Deposit[amount])
  def deposit_later(amount) = send_command(Deposit[amount])
  def transfer(to, amount) = send_command_sync(Transfer[to, amount])
  def balance = state[:balance]

  def handle(command, state)
    case command
    in Deposit(amount:)
      [:persist, MoneyDeposited[amount]]
    in Transfer(amount:) if state[:balance] < amount
      [:reject, :insufficient_funds]
    in Transfer(to:, amount:)
      # 出金イベントの永続化が成功した後で、相手のメールボックスに届く
      Account.new(to).deposit_later(amount)
      [:persist, MoneyTransferred[to, amount]]
    end
  end

  def apply_event(event, state)
    case event
    in MoneyDeposited(amount:)
      state.merge(balance: state[:balance] + amount)
    in MoneyTransferred(amount:)
      state.merge(balance: state[:balance] - amount)
    end
  end
end

Rakka.configure { |c| c.event_store = Rakka::EventStore::Memory.new }

alice = Account.new("alice")
bob = Account.new("bob")

alice.deposit(1000)
puts "alice=#{alice.balance} bob=#{bob.balance}"

puts "transfer 300: #{alice.transfer('bob', 300).first}"
puts "transfer 5000: #{alice.transfer('bob', 5000).inspect}"

sleep 0.1 # 入金は非同期に届く
puts "alice=#{alice.balance} bob=#{bob.balance}"

Rakka.shutdown
