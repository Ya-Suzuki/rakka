# frozen_string_literal: true

class CreateRakkaEvents < ActiveRecord::Migration[7.0]
  def change
    create_table :rakka_events, id: false do |t|
      t.uuid :id, primary_key: true, default: -> { "gen_random_uuid()" }
      t.string :stream_id, null: false
      t.integer :position, null: false
      t.string :event_type, null: false
      t.jsonb :data, null: false, default: {}
      t.timestamptz :created_at, null: false, default: -> { "NOW()" }

      t.index :stream_id
      t.index [:stream_id, :position], unique: true
    end
  end
end
