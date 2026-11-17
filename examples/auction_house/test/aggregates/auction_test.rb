require "test_helper"

# 集約のテストは「過去のイベント（given）+ コマンド（when）→ 新しいイベント（then）」で書ける。
# handle / apply_event は純粋関数なので、DBもアクターも要らない
class AuctionTest < ActiveSupport::TestCase
  OPENED = Auction::Opened["古伊万里の大皿", "alice", 1000, nil]

  setup { @actor = Auction.behavior("test") }

  def decide(given, command)
    state = given.reduce(@actor.initial_state) { |s, event| @actor.apply_event(event, s) }
    @actor.handle(command, state)
  end

  test "開始価格から入札できる" do
    assert_equal [:persist, Auction::BidPlaced["bob", 1000]],
                 decide([OPENED], Auction::PlaceBid["bob", 1000])
  end

  test "2件目以降は最高額 + 最小単位以上" do
    given = [OPENED, Auction::BidPlaced["bob", 1000]]

    assert_equal [:reject, :bid_too_low], decide(given, Auction::PlaceBid["carol", 1099])
    assert_equal [:persist, Auction::BidPlaced["carol", 1100]], decide(given, Auction::PlaceBid["carol", 1100])
  end

  test "出品者と最高額の入札者は入札できない" do
    given = [OPENED, Auction::BidPlaced["bob", 1000]]

    assert_equal [:reject, :seller_cannot_bid], decide(given, Auction::PlaceBid["alice", 5000])
    assert_equal [:reject, :already_leading], decide(given, Auction::PlaceBid["bob", 5000])
  end

  test "即決価格以上の入札は、入札と終了の2つのイベントになる" do
    given = [Auction::Opened["カメラ", "alice", 1000, 3000]]

    assert_equal [:persist, Auction::BidPlaced["bob", 3000], Auction::Closed["bob", 3000, "buyout"]],
                 decide(given, Auction::PlaceBid["bob", 9999])
  end

  test "終了は出品者だけができ、入札がなければ不成立" do
    assert_equal [:reject, :not_seller], decide([OPENED], Auction::Close["bob"])
    assert_equal [:persist, Auction::Closed[nil, nil, "seller"]], decide([OPENED], Auction::Close["alice"])
  end

  test "終了後は入札も終了もできない" do
    given = [OPENED, Auction::Closed[nil, nil, "seller"]]

    assert_equal [:reject, :closed], decide(given, Auction::PlaceBid["bob", 5000])
    assert_equal [:reject, :closed], decide(given, Auction::Close["alice"])
  end

  test "出品前は何もできず、出品は1回だけ" do
    assert_equal [:reject, :not_open], decide([], Auction::PlaceBid["bob", 1000])
    assert_equal [:reject, :already_opened], decide([OPENED], Auction::Open["別の皿", "alice", 1, nil])
  end

  test "出品の入力チェック" do
    assert_equal [:reject, :title_blank], decide([], Auction::Open[" ", "alice", 1000, nil])
    assert_equal [:reject, :invalid_price], decide([], Auction::Open["皿", "alice", 0, nil])
    assert_equal [:reject, :invalid_buyout_price], decide([], Auction::Open["皿", "alice", 1000, 1000])
  end

  test "history はイベントごとの状態を再生する" do
    states = Auction.history("test", [OPENED, Auction::BidPlaced["bob", 1000], Auction::BidPlaced["carol", 1500]])

    assert_equal [:draft, :open, :open, :open], states.map { _1[:status] }
    assert_equal [nil, nil, 1000, 1500], states.map { _1[:price] }
    assert_equal %w[bob carol], states.last[:bidders]
  end
end
