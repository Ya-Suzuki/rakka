ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    # Rakkaのシャード（Ractor）とイベントの発行スレッドはプロセスに1つずつなので、並列実行しない
    parallelize(workers: 1)

    # イベントはRakkaが自分のコネクションで書くので、テストのトランザクションでは
    # 巻き戻らない。読みモデルと合わせるため、テストごとに全部消す
    self.use_transactional_tests = false

    setup do
      ActiveRecord::Base.connection.execute(
        "TRUNCATE rakka_events, rakka_snapshots, auction_listings, bids, stream_checkpoints"
      )
    end

    # このテストで書いたイベントが読みモデルに反映され終わってから次へ進む
    # （反映が後から届くと、次のテストのデータに混ざる）
    teardown do
      Rakka.shutdown # メモリ上のアクターを捨てる。シャードは溜まっていた分を処理してから止まる
      Projections.wait_until_caught_up
    end

    def new_auction(title: "テスト品", seller: "seller", starting_price: 1000, buyout_price: nil)
      Auction.new(SecureRandom.alphanumeric(8).downcase).tap do |auction|
        auction.open(title:, seller:, starting_price:, buyout_price:)
      end
    end
  end
end
