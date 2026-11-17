# frozen_string_literal: true

require "pg"
require_relative "base"

module Rakka
  module EventStore
    # 本番用。Journalごとに1コネクションを持つ（シャードRactor数 + メイン用1本）。
    # 同時書き込みは UNIQUE(stream_id, position) による楽観ロックで検出するので、
    # 複数プロセス（Pumaワーカー等）が同じストリームに書いても壊れない
    class Postgres < Base
      SCHEMA = <<~SQL
        CREATE TABLE IF NOT EXISTS rakka_events (
          id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
          stream_id VARCHAR NOT NULL,
          position INT NOT NULL,
          event_type VARCHAR NOT NULL,
          data JSONB NOT NULL,
          created_at TIMESTAMPTZ DEFAULT NOW(),

          UNIQUE(stream_id, position)
        );

        CREATE INDEX IF NOT EXISTS idx_rakka_events_stream_id
          ON rakka_events(stream_id);

        CREATE TABLE IF NOT EXISTS rakka_snapshots (
          stream_id VARCHAR PRIMARY KEY,
          schema INT NOT NULL,
          version INT NOT NULL,
          state BYTEA NOT NULL,
          created_at TIMESTAMPTZ DEFAULT NOW()
        );
      SQL

      Connector = Data.define(:connection_string, :options) do
        def connect
          Journal.new(connection_string ? PG.connect(connection_string) : PG.connect(**options))
        end
      end

      class Journal
        def initialize(conn)
          @conn = conn
        end

        # 複数イベントを1文（=1トランザクション）で書く
        def append(stream_id, expected_version, events)
          return expected_version || size(stream_id) if events.empty?

          base = expected_version || size(stream_id)
          params = []
          rows = events.each_with_index.map do |event, i|
            n = params.size
            params.push(
              event.respond_to?(:id) ? event.id : SecureRandom.uuid_v7,
              stream_id,
              base + i,
              event.class.name,
              Serialization.dump(event)
            )
            "($#{n + 1}::uuid, $#{n + 2}::varchar, $#{n + 3}::int, $#{n + 4}::varchar, $#{n + 5}::jsonb)"
          end

          exec(<<~SQL, params)
            INSERT INTO rakka_events (id, stream_id, position, event_type, data)
            VALUES #{rows.join(", ")}
          SQL

          base + events.size
        rescue PG::UniqueViolation
          raise ConcurrencyError, "#{stream_id}: version #{base} was already written"
        end

        def read(stream_id, from_version = 0)
          result = exec(<<~SQL, [stream_id, from_version])
            SELECT event_type, data FROM rakka_events
            WHERE stream_id = $1 AND position >= $2::int
            ORDER BY position
          SQL
          result.map { |row| Serialization.load(row["event_type"], row["data"]) }
        end

        def size(stream_id)
          result = exec(<<~SQL, [stream_id])
            SELECT COALESCE(MAX(position) + 1, 0) AS size FROM rakka_events WHERE stream_id = $1
          SQL
          result[0]["size"].to_i
        end

        # stateはMarshalで保存する（Hashのキーの型やData/Timeなどをそのまま戻すため）。
        # 別プロセスが先に新しいものを保存していたら上書きしない
        def save_snapshot(stream_id, schema, version, state)
          exec(<<~SQL, [stream_id, schema, version, { value: Marshal.dump(state), format: 1 }])
            INSERT INTO rakka_snapshots (stream_id, schema, version, state)
            VALUES ($1, $2::int, $3::int, $4::bytea)
            ON CONFLICT (stream_id) DO UPDATE
              SET schema = EXCLUDED.schema, version = EXCLUDED.version,
                  state = EXCLUDED.state, created_at = NOW()
              WHERE rakka_snapshots.version <= EXCLUDED.version
          SQL
          :ok
        end

        def load_snapshot(stream_id)
          row = exec(<<~SQL, [stream_id]).first
            SELECT schema, version, state FROM rakka_snapshots WHERE stream_id = $1
          SQL
          return unless row

          [row["schema"].to_i, row["version"].to_i, Marshal.load(PG::Connection.unescape_bytea(row["state"]))]
        rescue ArgumentError, TypeError, NameError
          nil # 読めないスナップショット（クラスが消えた等）は無いものとして扱う
        end

        def close
          @conn.close
        rescue PG::Error
          nil
        end

        private

        def exec(sql, params)
          @conn.exec_params(sql, params)
        rescue PG::ConnectionBad, PG::UnableToSend
          # 接続が切れていたら張り直す。今回のコマンドは失敗させ、次から復帰する
          @conn.reset
          raise
        end
      end

      attr_reader :connector

      def initialize(connection_string: nil, **options)
        super()
        options = Rakka.configuration.postgres_options if options.empty? && connection_string.nil?
        @connector = Connector.new(
          connection_string: connection_string&.dup&.freeze,
          options: Ractor.make_shareable(options.transform_keys(&:to_sym).dup)
        )
      end

      def self.create_schema(connection_string: nil, **options)
        conn = connection_string ? PG.connect(connection_string) : PG.connect(**options)
        conn.exec(SCHEMA)
      ensure
        conn&.close
      end
    end
  end
end
