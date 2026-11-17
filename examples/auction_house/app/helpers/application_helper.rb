module ApplicationHelper
  REJECTIONS = {
    title_blank: "タイトルを入力してください",
    invalid_price: "開始価格は1円以上にしてください",
    invalid_buyout_price: "即決価格は開始価格より高くしてください",
    already_opened: "すでに出品されています",
    not_open: "まだ出品されていません",
    closed: "この出品は終了しています",
    seller_cannot_bid: "出品者は入札できません",
    already_leading: "あなたが最高額の入札者です",
    bid_too_low: "最低入札額に届いていません",
    not_seller: "出品を終了できるのは出品者だけです"
  }.freeze

  CLOSE_REASONS = { "buyout" => "即決", "seller" => "出品者が終了" }.freeze

  def rejection_message(reason) = REJECTIONS.fetch(reason, reason.to_s)

  def yen(amount) = amount ? "¥#{number_with_delimiter(amount)}" : "—"

  def event_label(event)
    case event
    in Auction::Opened then "出品"
    in Auction::BidPlaced then "入札"
    in Auction::Closed then "終了"
    end
  end

  def describe_event(event)
    case event
    in Auction::Opened(title:, seller:, starting_price:, buyout_price:)
      "#{seller} が「#{title}」を #{yen(starting_price)} から出品" +
        (buyout_price ? "（即決 #{yen(buyout_price)}）" : "")
    in Auction::BidPlaced(bidder:, amount:)
      "#{bidder} が #{yen(amount)} で入札"
    in Auction::Closed(winner: nil, reason:)
      "入札なしで終了（#{CLOSE_REASONS[reason]}）"
    in Auction::Closed(winner:, price:, reason:)
      "#{winner} が #{yen(price)} で落札（#{CLOSE_REASONS[reason]}）"
    end
  end

  def state_status_label(state)
    case state
    in { status: :open } then "受付中"
    in { status: :closed, winner: nil } then "不成立"
    in { status: :closed } then "落札"
    end
  end
end
