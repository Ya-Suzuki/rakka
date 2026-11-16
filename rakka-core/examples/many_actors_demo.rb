# frozen_string_literal: true

# 多数のアクターを少数のRactorに載せたときのメモリと処理時間を見る。
#
#   ruby examples/many_actors_demo.rb [アクター数]

require_relative "../lib/rakka"
require_relative "bank_account"

def rss_mb
  File.read("/proc/self/status")[/VmRSS:\s+(\d+)/, 1].to_i / 1024.0
rescue Errno::ENOENT
  `ps -o rss= -p #{Process.pid}`.to_i / 1024.0
end

count = (ARGV[0] || 50_000).to_i

system = Rakka::ActorSystem.new(
  event_store: Rakka::EventStore::Memory.new,
  max_actors_per_shard: count
)

puts "=== #{count} actors on #{system.shard_count} shard Ractors ==="
before = rss_mb
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

count.times do |i|
  BankAccount.new("account-#{i}", system: system).deposit(BankAccount::Deposit[i])
end

elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
stats = system.stats

puts "Ractors:        #{Ractor.count}"
puts "Active actors:  #{stats[:active_count]} (per shard: #{stats[:shards].map { |s| s[:active_count] }.inspect})"
puts "RSS:            #{before.round(1)}MB -> #{rss_mb.round(1)}MB " \
     "(#{((rss_mb - before) * 1024 / count).round(2)}KB/actor, イベントストア分を含む)"
puts "Elapsed:        #{elapsed.round(2)}s (#{(count / elapsed).round} commands/s, 1スレッドから同期送信)"

system.stop
