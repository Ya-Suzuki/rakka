require "test_helper"

# 同じ出品への入札は、アクターのメールボックスに並んで1件ずつ処理される。
# ロックを書かなくても「読んで比べて書く」が競合しないことを、同時入札で確かめる
class ConcurrentBiddingTest < ActiveSupport::TestCase
  test "大勢が同時に入札しても、受理された入札は単調に増え、取りこぼしもない" do
    auction = new_auction(starting_price: 1000)

    results = 10.times.map do |t|
      Thread.new do
        5.times.map do
          amount = Auction.minimum_bid(auction.state) + rand(0..2) * Auction::MIN_INCREMENT
          [amount, auction.bid("bidder-#{t}", amount)]
        end
      end
    end.flat_map(&:value)

    accepted = results.filter_map { |amount, result| amount if result.first == :ok }
    bids = StoredEvent.for_stream(Auction.stream_id(auction.id)).map(&:event).grep(Auction::BidPlaced)

    assert_operator accepted.size, :>, 0
    assert_equal accepted.sort, bids.map(&:amount)
    assert bids.map(&:amount).each_cons(2).all? { |a, b| b >= a + Auction::MIN_INCREMENT }
    assert_equal accepted.max, auction.state[:price]
  end
end
