# 入札者ランキング。読みモデル（bids / auction_listings）から集計する
class Leaderboard
  Row = Data.define(:bidder, :bids, :auctions, :wins, :spent)

  def self.top(limit = 10)
    wins = AuctionListing.where(status: "sold").group(:winner)
                         .pluck(:winner, Arel.sql("count(*)"), Arel.sql("sum(final_price)"))
                         .to_h { |winner, count, sum| [winner, [count, sum]] }

    Bid.group(:bidder)
       .pluck(:bidder, Arel.sql("count(*)"), Arel.sql("count(distinct auction_id)"))
       .map { |bidder, bids, auctions| Row[bidder, bids, auctions, *wins.fetch(bidder, [0, 0])] }
       .sort_by { |row| [-row.wins, -row.spent, -row.bids, row.bidder] }
       .first(limit)
  end
end
