# サンプルの出品と入札を入れる。実行するたびに新しい出品が増える（イベントは消さない）

def open_auction(title, seller, starting_price, buyout_price = nil)
  Auction.new(SecureRandom.alphanumeric(8).downcase).tap do |auction|
    auction.open(title:, seller:, starting_price:, buyout_price:)
  end
end

plate = open_auction("古伊万里の大皿", "yamada", 5000)
plate.bid("sato", 5000)
plate.bid("suzuki", 5500)
plate.bid("sato", 6000)
plate.bid("tanaka", 8000)
plate.bid("suzuki", 8500)

camera = open_auction("ビンテージのフィルムカメラ", "kato", 12_000, 30_000)
camera.bid("tanaka", 12_000)
camera.bid("sato", 15_000)
camera.bid("tanaka", 40_000) # 即決価格以上 → 即決で落札

tenugui = open_auction("手ぬぐい 5枚セット", "suzuki", 800)
tenugui.bid("yamada", 800)
tenugui.bid("kato", 1200)
tenugui.close("suzuki")

toy = open_auction("昭和のブリキ玩具", "sato", 3000)
toy.close("sato") # 入札なし → 不成立

rack = open_auction("木製のレコードラック", "tanaka", 4000)
rack.bid("kato", 4000)

Projections.wait_until_caught_up
puts "出品 #{AuctionListing.count}件 / 入札 #{Bid.count}件 / イベント #{StoredEvent.count}件"
