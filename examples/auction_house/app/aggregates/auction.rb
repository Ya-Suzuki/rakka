# frozen_string_literal: true

# 1つの出品 = 1つのアクター。
#
# 同じ出品への入札は、このアクターのメールボックスに並んで1件ずつ処理される。
# 「最高額を読んで、それより高ければ書く」がロックなしで正しく動くのはこのため。
#
# handle / apply_event はシャードRactorの中で実行されるので、ActiveRecordや
# グローバルな状態には触れない（触れるのは引数の command / event / state だけ）。
class Auction < Rakka::PersistentActor
  MIN_INCREMENT = 100

  # --- Commands ---
  Open = Data.define(:title, :seller, :starting_price, :buyout_price)
  PlaceBid = Data.define(:bidder, :amount)
  Close = Data.define(:requested_by)

  # --- Events（過去形。一度書いたら変えない） ---
  Opened = Data.define(:title, :seller, :starting_price, :buyout_price)
  BidPlaced = Data.define(:bidder, :amount)
  # winner が nil なら入札なしで終了（不成立）。reason は "buyout" か "seller"
  Closed = Data.define(:winner, :price, :reason)

  def initial_state
    { status: :draft, bid_count: 0, bidders: [] }
  end

  # --- 公開API（コントローラから呼ぶ） ---

  def open(title:, seller:, starting_price:, buyout_price: nil)
    send_command_sync(Open[title, seller, starting_price, buyout_price])
  end

  def bid(bidder, amount)
    send_command_sync(PlaceBid[bidder, amount])
  end

  def close(requested_by)
    send_command_sync(Close[requested_by])
  end

  # 次に入札できる最低額
  def self.minimum_bid(state)
    state[:price] ? state[:price] + MIN_INCREMENT : state[:starting_price]
  end

  # イベント列を順に適用し、各時点の状態を返す（タイムトラベル表示用）
  def self.history(id, events)
    actor = behavior(id)
    events.each_with_object([actor.initial_state]) do |event, states|
      states << actor.apply_event(event, states.last)
    end
  end

  # --- コマンド → イベント（判断） ---

  def handle(command, state)
    case command
    in Open if state[:status] != :draft
      [:reject, :already_opened]
    in Open(title:, seller:, starting_price:, buyout_price:)
      return [:reject, :title_blank] if title.strip.empty?
      return [:reject, :invalid_price] unless starting_price.positive?
      return [:reject, :invalid_buyout_price] if buyout_price && buyout_price <= starting_price

      [:persist, Opened[title, seller, starting_price, buyout_price]]

    in PlaceBid if state[:status] != :open
      [:reject, state[:status] == :closed ? :closed : :not_open]
    in PlaceBid(bidder:) if bidder == state[:seller]
      [:reject, :seller_cannot_bid]
    in PlaceBid(bidder:) if bidder == state[:leader]
      [:reject, :already_leading]
    in PlaceBid(amount:) if amount < self.class.minimum_bid(state)
      [:reject, :bid_too_low]
    in PlaceBid(bidder:, amount:) if state[:buyout_price] && amount >= state[:buyout_price]
      # 即決: 1つのコマンドから2つのイベント。同じトランザクションで書かれる
      price = state[:buyout_price]
      [:persist, BidPlaced[bidder, price], Closed[bidder, price, "buyout"]]
    in PlaceBid(bidder:, amount:)
      [:persist, BidPlaced[bidder, amount]]

    in Close if state[:status] != :open
      [:reject, state[:status] == :closed ? :closed : :not_open]
    in Close(requested_by:) if requested_by != state[:seller]
      [:reject, :not_seller]
    in Close
      [:persist, Closed[state[:leader], state[:price], "seller"]]
    end
  end

  # --- イベント → 状態（純粋関数） ---

  def apply_event(event, state)
    case event
    in Opened(title:, seller:, starting_price:, buyout_price:)
      state.merge(status: :open, title:, seller:, starting_price:, buyout_price:)
    in BidPlaced(bidder:, amount:)
      state.merge(price: amount, leader: bidder, bid_count: state[:bid_count] + 1,
                  bidders: state[:bidders] | [bidder])
    in Closed(winner:, price:, reason:)
      state.merge(status: :closed, winner:, final_price: price, close_reason: reason)
    end
  end
end
