# frozen_string_literal: true

require "securerandom"
require_relative "../lib/rakka"
require_relative "bank_account"

# 設定（環境変数 or 直接指定）
Rakka.configure do |c|
  c.postgres_pool_size = 3
  # c.postgres_host = "localhost"  # デフォルト or ENV["RAKKA_POSTGRES_HOST"]
  # c.postgres_database = "rakka_development"
end

# スキーマ作成
Rakka::EventStore::Postgres.create_schema(**Rakka.configuration.postgres_options)

# EventStore作成（設定を自動で読み込む）
event_store = Rakka::EventStore::Postgres.new
Rakka.configure { |c| c.event_store = event_store }

puts "=== PostgreSQL EventStore Demo (with ShardCoordinator) ==="

# 複数アカウントを作成してシャード分散を確認
accounts = 5.times.map do |i|
  id = "account-#{SecureRandom.hex(4)}"
  BankAccount.new(id)
end

puts "\n--- Shard distribution ---"
accounts.each_with_index do |account, i|
  account.deposit(BankAccount::Deposit[1000 * (i + 1)])
  puts "Account #{i}: balance=#{account.balance}"
end

stats = event_store.stats
puts "\nShardCoordinator stats:"
puts "  Load per shard: #{stats[:load].inspect}"
puts "  Assignments: #{stats[:assignments].size} streams"

puts "\n--- Single account test ---"
account = accounts.first
puts "Account ID: #{account.id}"
puts "Balance: #{account.balance}"

account.withdraw(BankAccount::Withdraw[300])
puts "After withdraw(300): #{account.balance}"

result = account.withdraw(BankAccount::Withdraw[10000])
puts "Withdraw(10000) result: #{result.inspect}"

puts "\n--- Recovery test ---"
recovered = BankAccount.new(account.id)
puts "Recovered balance: #{recovered.balance}"

puts "\n--- Release test ---"
event_store.release("BankAccount-#{account.id}")
stats_after = event_store.stats
puts "After release - Load per shard: #{stats_after[:load].inspect}"
