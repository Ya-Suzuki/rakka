# 読みモデル（クエリ側）。どれもイベントから作り直せるので、消しても
# bin/rails projections:rebuild で元に戻る
class CreateReadModels < ActiveRecord::Migration[8.1]
  def change
    # 出品一覧
    create_table :auction_listings do |t|
      t.string :auction_id, null: false, index: { unique: true }
      t.string :title, null: false
      t.string :seller, null: false
      t.integer :starting_price, null: false
      t.integer :buyout_price
      t.integer :current_price
      t.string :leader
      t.integer :bid_count, null: false, default: 0
      t.string :status, null: false # open / sold / unsold
      t.string :winner
      t.integer :final_price
      t.string :close_reason
      t.datetime :opened_at, null: false
      t.datetime :closed_at
    end

    # 入札の記録（ランキングの集計元）
    create_table :bids do |t|
      t.string :auction_id, null: false
      t.integer :version, null: false
      t.string :bidder, null: false, index: true
      t.integer :amount, null: false
      t.datetime :placed_at, null: false
      t.index %i[auction_id version], unique: true
    end

    # ストリームごとに、どのversionまで読みモデルに反映したか
    create_table :stream_checkpoints, id: false do |t|
      t.string :stream_id, null: false, primary_key: true
      t.integer :version, null: false, default: 0
    end
  end
end
