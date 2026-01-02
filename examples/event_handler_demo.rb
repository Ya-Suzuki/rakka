# frozen_string_literal: true

require_relative "../lib/rakka"
require_relative "bank_account"

Rakka.configure { |c| c.event_store = Rakka::EventStore::Memory.new }

puts "=== Event Handler Demo ==="

# イベントハンドラを登録
Rakka.subscribe(BankAccount::MoneyDeposited) do |event, metadata|
  puts "[Handler] Deposit received: #{event.amount} yen"
  puts "          Stream: #{metadata[:stream_id]}"
end

Rakka.subscribe(BankAccount::MoneyWithdrawn) do |event, metadata|
  puts "[Handler] Withdrawal: #{event.amount} yen"
end

# 全イベントをログ
Rakka.subscribe_all do |event, metadata|
  puts "[Audit] Event: #{event.class.name} at #{Time.now}"
end

# アカウント操作
account = BankAccount.new("account-1")

puts "\n--- Deposit ---"
account.deposit(BankAccount::Deposit[1000])

puts "\n--- Withdraw ---"
account.withdraw(BankAccount::Withdraw[300])

puts "\n--- Rejected (no handler called) ---"
result = account.withdraw(BankAccount::Withdraw[10000])
puts "Result: #{result.inspect}"

puts "\nFinal balance: #{account.balance}"
