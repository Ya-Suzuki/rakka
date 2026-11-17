namespace :projections do
  desc "読みモデルを全部消して、イベントストアの全イベントから作り直す"
  task rebuild: :environment do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Projections.rebuild!
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    puts "#{StoredEvent.count}件のイベントから作り直しました " \
         "（出品 #{AuctionListing.count}件 / 入札 #{Bid.count}件、#{elapsed.round(2)}秒）"
  end
end

namespace :auction do
  desc "1つの出品に大勢が同時に入札する（AUCTION_ID=既存の出品 THREADS=20 BIDS=10）"
  task bidding_war: :environment do
    threads = Integer(ENV.fetch("THREADS", 20))
    per_thread = Integer(ENV.fetch("BIDS", 10))

    id = ENV["AUCTION_ID"] || SecureRandom.alphanumeric(8).downcase.tap do |new_id|
      Auction.new(new_id).open(title: "競り合いデモ", seller: "auctioneer", starting_price: 1000)
    end
    auction = Auction.new(id)
    before = StoredEvent.for_stream(auction.stream_id).count

    puts "#{threads}人が #{per_thread}回ずつ、同じ出品（#{id}）に同時に入札します..."
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    results = threads.times.map do |t|
      Thread.new do
        bidder = "bidder-#{t + 1}"
        per_thread.times.map do
          # 最新の価格を見てから入札する。見てから入札が届くまでの間に、他の人の入札が
          # 先に処理されているかもしれない。その判断はアクターが1件ずつ行う
          amount = Auction.minimum_bid(auction.state) + rand(0..3) * Auction::MIN_INCREMENT
          [amount, auction.bid(bidder, amount)]
        end
      end
    end.flat_map(&:value)

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    accepted = results.filter_map { |amount, result| amount if result.first == :ok }
    rejected = results.filter_map { |_, result| result.last if result.first == :rejected }.tally
    bids = StoredEvent.for_stream(auction.stream_id).offset(before).map(&:event).grep(Auction::BidPlaced)
    increasing = bids.map(&:amount).each_cons(2).all? { |a, b| b >= a + Auction::MIN_INCREMENT }

    puts
    puts "入札 #{results.size}件（#{(results.size / elapsed).round}件/秒）"
    puts "  受理: #{accepted.size}件"
    rejected.each { |reason, count| puts "  拒否: #{count}件（#{ApplicationController.helpers.rejection_message(reason)}）" }
    puts
    puts "確認"
    puts "  受理した入札 = 記録された入札イベント: #{accepted.sort == bids.map(&:amount) ? 'OK' : 'NG'}"
    puts "  入札額は常に前の最高額 + #{Auction::MIN_INCREMENT}円以上: #{increasing ? 'OK' : 'NG'}"
    puts "  現在価格 = 受理した最高額（#{accepted.max}円）: #{auction.state[:price] == accepted.max ? 'OK' : 'NG'}"
    puts
    puts "画面で見る: http://localhost:3000/auctions/#{id}"
  end
end
