# frozen_string_literal: true

require_relative "../lib/rakka"

class BankAccount < Rakka::PersistentActor
  # Commands
  Deposit = Data.define(:amount)
  Withdraw = Data.define(:amount)

  # Events
  MoneyDeposited = Data.define(:amount)
  MoneyWithdrawn = Data.define(:amount)

  def initial_state
    { balance: 0 }
  end

  def deposit(cmd)
    send_command_sync(cmd)
  end

  def withdraw(cmd)
    send_command_sync(cmd)
  end

  def balance
    state[:balance]
  end

  # コマンドを処理してイベントを返す
  def handle(command, state)
    case command
    in Deposit(amount:)
      [:persist, MoneyDeposited[amount]]

    in Withdraw(amount:)
      if state[:balance] >= amount
        [:persist, MoneyWithdrawn[amount]]
      else
        [:reject, :insufficient_funds]
      end
    end
  end

  # イベントを適用して新しい状態を返す
  def apply_event(event, state)
    case event
    in MoneyDeposited(amount:)
      state.merge(balance: state[:balance] + amount)
    in MoneyWithdrawn(amount:)
      state.merge(balance: state[:balance] - amount)
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

  # 残高不足（拒否される）
  account.withdraw(BankAccount::Withdraw[1000])
  puts "After rejected withdraw: #{account.balance}"

  puts "\n--- Recovery test ---"
  recovered = BankAccount.new("account-123")
  puts "Recovered balance: #{recovered.balance}"
end
