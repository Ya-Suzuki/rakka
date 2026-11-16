# frozen_string_literal: true

require_relative "../lib/rakka"
require_relative "bank_account"

Rakka.configure do |c|
  c.event_store = Rakka::EventStore::Memory.new
  c.passivate_after = 2 # 2秒コマンドが来なければメモリから解放
end

puts "=== Passivation Demo ==="

account1 = BankAccount.new("account-1")
account1.deposit(BankAccount::Deposit[1000])
account2 = BankAccount.new("account-2")
account2.deposit(BankAccount::Deposit[2000])

puts "Active actors: #{Rakka.system.stats[:active_count]}"

puts "\nWaiting 1.5 seconds, then touching account-1..."
sleep 1.5
puts "account-1 balance: #{account1.balance}"

puts "\nWaiting 1.5 more seconds (account-2 should passivate)..."
sleep 1.5
puts "Active actors: #{Rakka.system.stats[:active_count]}"

puts "\nUsing account-2 again (rehydrated from events)..."
puts "account-2 balance: #{account2.balance}"
puts "Active actors: #{Rakka.system.stats[:active_count]}"

Rakka.shutdown
