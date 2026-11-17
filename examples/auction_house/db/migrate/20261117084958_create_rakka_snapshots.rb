# frozen_string_literal: true

class CreateRakkaSnapshots < ActiveRecord::Migration[7.0]
  def change
    create_table :rakka_snapshots, id: false do |t|
      t.string :stream_id, null: false, primary_key: true
      t.integer :schema, null: false
      t.integer :version, null: false
      t.binary :state, null: false
      t.timestamptz :created_at, null: false, default: -> { "NOW()" }
    end
  end
end
