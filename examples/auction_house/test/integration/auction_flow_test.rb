require "test_helper"

class AuctionFlowTest < ActionDispatch::IntegrationTest
  def login(name) = patch(session_path, params: { name: })

  def create_auction(**params)
    post auctions_path, params: { title: "古伊万里の大皿", starting_price: 1000, **params }
    response.location.split("/").last
  end

  test "出品して、入札して、一覧に反映される" do
    login "alice"
    id = create_auction(buyout_price: 5000)
    follow_redirect!
    assert_select "h1", "古伊万里の大皿"

    login "bob"
    post auction_bids_path(id), params: { amount: 1000 }
    follow_redirect!
    assert_select ".flash--notice", "¥1,000 で入札しました"

    post auction_bids_path(id), params: { amount: 2000 }
    follow_redirect!
    assert_select ".flash--alert", "あなたが最高額の入札者です"

    login "carol"
    post auction_bids_path(id), params: { amount: 6000 }
    follow_redirect!
    assert_select ".flash--notice", "即決価格 ¥5,000 で落札しました！"

    Projections.wait_until_caught_up
    get root_path
    assert_select "td", "古伊万里の大皿"
    assert_select ".badge--sold", "落札"
  end

  test "イベント履歴から過去の時点の状態を表示できる" do
    login "alice"
    id = create_auction
    login "bob"
    post auction_bids_path(id), params: { amount: 1000 }
    login "carol"
    post auction_bids_path(id), params: { amount: 1500 }

    get auction_path(id)
    assert_select ".timeline__item", 3
    assert_select ".price", "¥1,500"

    get auction_path(id, at: 2)
    assert_select ".timetravel", /v2 時点の状態/
    assert_select ".price", "¥1,000"
    assert_select ".timeline__item.is-future", 1
    assert_select "form.bid", 0 # 過去の表示では入札できない
  end

  test "出品者だけが終了できる" do
    login "alice"
    id = create_auction
    login "bob"
    post close_auction_path(id)
    follow_redirect!
    assert_select ".flash--alert", "出品を終了できるのは出品者だけです"

    login "alice"
    post close_auction_path(id)
    follow_redirect!
    assert_select ".badge--unsold", "不成立"
  end

  test "入力が不正なら出品しない" do
    post auctions_path, params: { title: "皿", starting_price: 0 }
    follow_redirect!
    assert_select ".flash--alert", "開始価格は1円以上にしてください"
  end

  test "存在しない出品は404" do
    get auction_path("missing")
    assert_response :not_found
  end
end
