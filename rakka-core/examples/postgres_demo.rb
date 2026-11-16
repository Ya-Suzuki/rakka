# frozen_string_literal: true

require "securerandom"
require_relative "../lib/rakka"
require_relative "bank_account"

# 設定（環境変数 or 直接指定）
Rakka.configure do |c|
  c.shard_count = 3 # シャードRactor数 = PostgreSQLコネクション数（+メイン用1本）
  # c.postgres_host = "localhost"  # デフォルト or ENV["RAKKA_POSTGRES_HOST"]
  # c.postgres_database = "rakka_development"
end

# スキーマ作成
Rakka::EventStore::Postgres.create_schema(**Rakka.configuration.postgres_options)

# EventStore作成（設定を自動で読み込む）
event_store = Rakka::EventStore::Postgres.new
Rakka.configure { |c| c.event_store = event_store }

puts "=== PostgreSQL EventStore Demo ==="

accounts = 5.times.map { BankAccount.new("account-#{SecureRandom.hex(4)}") }

puts "\n--- Shard distribution ---"
accounts.each_with_index do |account, i|
  account.deposit(BankAccount::Deposit[1000 * (i + 1)])
  puts "Account #{i}: balance=#{account.balance} shard=#{Rakka.system.shard_index(account.stream_id)}"
end
puts "Actors per shard: #{Rakka.system.stats[:shards].map { |s| s[:active_count] }.inspect}"

puts "\n--- Single account test ---"
account = accounts.first
account.withdraw(BankAccount::Withdraw[300])
puts "After withdraw(300): #{account.balance}"
puts "Withdraw(10000) result: #{account.withdraw(BankAccount::Withdraw[10_000]).inspect}"

puts "\n--- Recovery test ---"
account.stop # メモリから解放 → 次のアクセスでPostgreSQLから復元
puts "Recovered balance: #{account.balance}"

puts "\n--- Optimistic concurrency test ---"
# 別プロセスのライターを模して、アクターを通さずに直接書く
event_store.append(account.stream_id, BankAccount::MoneyWithdrawn[700])
# アクターのキャッシュは古いが、競合を検知して最新状態(0)で判定し直す
puts "Withdraw(100) after external write: #{account.withdraw(BankAccount::Withdraw[100]).inspect}"
puts "Balance: #{account.balance}"

Rakka.shutdown
