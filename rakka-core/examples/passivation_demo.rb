# frozen_string_literal: true

require_relative "../lib/rakka"
require_relative "bank_account"

Rakka.configure { |c| c.event_store = Rakka::EventStore::Memory.new }

# 5秒でpassivateするRegistry
registry = Rakka::ActorRegistry.new(passivate_after: 5)

puts "=== Passivation Demo ==="

# アカウント取得（新規作成）
account1 = registry.get_or_create(BankAccount, "account-1")
puts "Created account1: #{account1.id}"
account1.deposit(BankAccount::Deposit[1000])
puts "Deposited 1000, balance: #{account1.balance}"

account2 = registry.get_or_create(BankAccount, "account-2")
puts "Created account2: #{account2.id}"
account2.deposit(BankAccount::Deposit[2000])
puts "Deposited 2000, balance: #{account2.balance}"

puts "\nRegistry stats: #{registry.stats.inspect}"
puts "\nWaiting 3 seconds..."
sleep 3

# account1を再度触る（last_activeが更新される）
account1_again = registry.get_or_create(BankAccount, "account-1")
puts "Touched account1, balance: #{account1_again.balance}"

puts "\nRegistry stats: #{registry.stats.inspect}"
puts "\nWaiting 4 more seconds (account2 should passivate)..."
sleep 4

puts "\nRegistry stats after wait: #{registry.stats.inspect}"

# account2を再度取得（再活性化）
puts "\nGetting account2 again (should rehydrate from events)..."
account2_rehydrated = registry.get_or_create(BankAccount, "account-2")
puts "account2 balance after rehydration: #{account2_rehydrated.balance}"

puts "\nFinal registry stats: #{registry.stats.inspect}"

# クリーンアップ
registry.stop
puts "\nRegistry stopped."
