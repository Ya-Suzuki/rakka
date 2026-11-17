require "test_helper"

class ProjectionsTest < ActiveSupport::TestCase
  test "書き込まれたイベントが読みモデルに反映される" do
    auction = new_auction(title: "皿", starting_price: 1000, buyout_price: 5000)
    auction.bid("bob", 1000)
    auction.bid("carol", 9000) # 即決

    Projections.wait_until_caught_up

    listing = AuctionListing.find_by!(auction_id: auction.id)
    # 出品・入札・即決（入札 + 終了）で4イベント
    assert_equal ["sold", "carol", 5000, 2, 4],
                 [listing.status, listing.winner, listing.final_price, listing.bid_count,
                  StreamCheckpoint.find(auction.stream_id).version]
    assert_equal [["bob", 1000], ["carol", 5000]], Bid.order(:version).pluck(:bidder, :amount)
  end

  test "同じイベントが2回届いても、2回は反映しない" do
    auction = new_auction
    auction.bid("bob", 1000)
    Projections.wait_until_caught_up

    Projections.apply(Auction::BidPlaced["bob", 1000], { stream_id: auction.stream_id, actor_id: auction.id, version: 2 })

    assert_equal 1, AuctionListing.find_by!(auction_id: auction.id).bid_count
    assert_equal 1, Bid.count
  end

  test "途中のイベントが届かなかったら、イベントストアから読んで埋める" do
    auction = new_auction
    Projections.wait_until_caught_up

    # イベントの発行を経由せずに書く（発行前にプロセスが落ちた、の再現）
    store = Rakka.event_store
    store.append(auction.stream_id, Auction::BidPlaced["bob", 1000], expected_version: 1)
    store.append(auction.stream_id, Auction::BidPlaced["carol", 1100], expected_version: 2)
    Projections.wait_until_caught_up(timeout: 0.1) rescue nil
    refute Projections.caught_up?

    # 次のイベント（v4）が届いた時点で、v2・v3 も埋まる
    auction.stop # キャッシュを捨てて、直接書いた分を読み直させる
    auction.bid("dave", 1200)
    Projections.wait_until_caught_up

    assert_equal %w[bob carol dave], Bid.order(:version).pluck(:bidder)
    assert_equal 3, AuctionListing.find_by!(auction_id: auction.id).bid_count
  end

  test "読みモデルは消してもイベントから作り直せる" do
    auction = new_auction(seller: "alice")
    auction.bid("bob", 1000)
    auction.close("alice")
    Projections.wait_until_caught_up
    expected = AuctionListing.find_by!(auction_id: auction.id).attributes.except("id")

    AuctionListing.update_all(title: "壊れたデータ", bid_count: 99)
    Bid.delete_all
    Projections.rebuild!

    assert_equal expected.except("opened_at", "closed_at"),
                 AuctionListing.find_by!(auction_id: auction.id).attributes.except("id", "opened_at", "closed_at")
    assert_equal 1, Bid.count
    assert Projections.caught_up?
  end
end
