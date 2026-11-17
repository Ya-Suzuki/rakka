# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_11_17_090000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "auction_listings", force: :cascade do |t|
    t.string "auction_id", null: false
    t.string "title", null: false
    t.string "seller", null: false
    t.integer "starting_price", null: false
    t.integer "buyout_price"
    t.integer "current_price"
    t.string "leader"
    t.integer "bid_count", default: 0, null: false
    t.string "status", null: false
    t.string "winner"
    t.integer "final_price"
    t.string "close_reason"
    t.datetime "opened_at", null: false
    t.datetime "closed_at"
    t.index ["auction_id"], name: "index_auction_listings_on_auction_id", unique: true
  end

  create_table "bids", force: :cascade do |t|
    t.string "auction_id", null: false
    t.integer "version", null: false
    t.string "bidder", null: false
    t.integer "amount", null: false
    t.datetime "placed_at", null: false
    t.index ["auction_id", "version"], name: "index_bids_on_auction_id_and_version", unique: true
    t.index ["bidder"], name: "index_bids_on_bidder"
  end

  create_table "rakka_events", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "stream_id", null: false
    t.integer "position", null: false
    t.string "event_type", null: false
    t.jsonb "data", default: {}, null: false
    t.timestamptz "created_at", default: -> { "now()" }, null: false
    t.index ["stream_id", "position"], name: "index_rakka_events_on_stream_id_and_position", unique: true
    t.index ["stream_id"], name: "index_rakka_events_on_stream_id"
  end

  create_table "rakka_snapshots", primary_key: "stream_id", id: :string, force: :cascade do |t|
    t.integer "schema", null: false
    t.integer "version", null: false
    t.binary "state", null: false
    t.timestamptz "created_at", default: -> { "now()" }, null: false
  end

  create_table "stream_checkpoints", primary_key: "stream_id", id: :string, force: :cascade do |t|
    t.integer "version", default: 0, null: false
  end
end
