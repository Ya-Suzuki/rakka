# frozen_string_literal: true

require_relative "../lib/rakka"

class BankAccount < Rakka::PersistentActor
  # Commands
  Deposit = Data.define(:amount)
  Withdraw = Data.define(:amount)

  # Events
  MoneyDeposited = Data.define(:amount)
  MoneyWithdrawn = Data.define(:amount)

  # Errors
  class InsufficientFunds < StandardError; end

  def initial_state
    { balance: 0 }
  end

  def deposit(cmd)
    persist(MoneyDeposited[cmd.amount])
  end

  def withdraw(cmd)
    raise InsufficientFunds if state[:balance] < cmd.amount

    persist(MoneyWithdrawn[cmd.amount])
  end

  def balance
    state[:balance]
  end

  def apply(event)
    case event
    in MoneyDeposited(amount:)
      @state = state.merge(balance: state[:balance] + amount)
    in MoneyWithdrawn(amount:)
      @state = state.merge(balance: state[:balance] - amount)
    end
  end
end

# --- 使用例 ---
if __FILE__ == $0
  # 設定
  Rakka.configure do |config|
    config.event_store = Rakka::EventStore::Memory.new
  end

  # アカウント作成
  account = BankAccount.new("account-123")
  puts "Initial balance: #{account.balance}"

  # 入金
  account.deposit(BankAccount::Deposit[1000])
  puts "After deposit: #{account.balance}"

  # 出金
  account.withdraw(BankAccount::Withdraw[300])
  puts "After withdraw: #{account.balance}"

  # 残高不足
  begin
    account.withdraw(BankAccount::Withdraw[1000])
  rescue BankAccount::InsufficientFunds
    puts "Withdraw rejected: Insufficient funds"
  end

  puts "Final balance: #{account.balance}"

  # 復元テスト: 同じIDで新しいインスタンスを作る
  puts "\n--- Recovery test ---"
  recovered = BankAccount.new("account-123")
  puts "Recovered balance: #{recovered.balance}"
end
