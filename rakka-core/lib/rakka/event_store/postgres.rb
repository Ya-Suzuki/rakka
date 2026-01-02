# frozen_string_literal: true

require "pg"
require "json"
require "securerandom"
require_relative "../shard_coordinator"

module Rakka
  module EventStore
    class Postgres
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
      SQL

      attr_reader :coordinator

      def initialize(pool_size: nil, connection_string: nil, **options)
        config = Rakka.configuration
        @pool_size = pool_size || config.postgres_pool_size
        @connection_string = connection_string
        @options = options.empty? ? config.postgres_options : options
        @coordinator = ShardCoordinator.new(shard_count: @pool_size)

        # ワーカーRactorプールを作成
        frozen_opts = Ractor.make_shareable(@options.transform_keys(&:to_s))
        frozen_conn_str = @connection_string&.freeze

        @workers = @pool_size.times.map do |i|
          Ractor.new(i, frozen_conn_str, frozen_opts) do |worker_id, conn_str, opts|
            conn = if conn_str
                     PG.connect(conn_str)
                   else
                     symbolized = opts.transform_keys(&:to_sym)
                     PG.connect(**symbolized)
                   end

            loop do
              msg = Ractor.receive

              case msg
              in [:append, stream_id, event_id, event_type, data, reply_port]
                begin
                  result = conn.exec_params(<<~SQL, [event_id, stream_id, event_type, data])
                    INSERT INTO rakka_events (id, stream_id, position, event_type, data)
                    VALUES (
                      $1::uuid,
                      $2::varchar,
                      (SELECT COALESCE(MAX(position) + 1, 0) FROM rakka_events WHERE stream_id = $2::varchar),
                      $3::varchar,
                      $4::jsonb
                    )
                    RETURNING position
                  SQL
                  reply_port.send(:ok)
                rescue PG::UniqueViolation => e
                  reply_port.send([:error, :conflict])
                rescue => e
                  reply_port.send([:error, e.message])
                end

              in [:read_stream, stream_id, reply_port]
                result = conn.exec_params(<<~SQL, [stream_id])
                  SELECT event_type, data FROM rakka_events
                  WHERE stream_id = $1
                  ORDER BY position
                SQL
                reply_port.send(result.map { |row| [row["event_type"], row["data"]] })

              in [:stream_size, stream_id, reply_port]
                result = conn.exec_params(<<~SQL, [stream_id])
                  SELECT COUNT(*) FROM rakka_events WHERE stream_id = $1
                SQL
                reply_port.send(result[0]["count"].to_i)
              end
            end
          end
        end
      end

      def self.create_schema(connection_string: nil, **options)
        conn = if connection_string
                 PG.connect(connection_string)
               else
                 PG.connect(**options)
               end
        conn.exec(SCHEMA)
        conn.close
      end

      def ractor
        # PersistentActor互換用: coordinatorで振り分けるラッパーRactorを返す
        @router ||= create_router
      end

      def append(stream_id, event)
        port = Ractor::Port.new
        worker = worker_for(stream_id)
        event_id = event.respond_to?(:id) ? event.id : SecureRandom.uuid_v7
        event_type = event.class.name
        data = serialize_event(event)
        worker.send([:append, stream_id, event_id, event_type, data, port])
        port.receive
      end

      def read_stream(stream_id)
        port = Ractor::Port.new
        worker = worker_for(stream_id)
        worker.send([:read_stream, stream_id, port])
        rows = port.receive
        rows.map { |event_type, data| deserialize_event(event_type, data) }
      end

      def stream_size(stream_id)
        port = Ractor::Port.new
        worker = worker_for(stream_id)
        worker.send([:stream_size, stream_id, port])
        port.receive
      end

      def release(stream_id)
        @coordinator.release(stream_id)
      end

      def stats
        @coordinator.stats
      end

      private

      def worker_for(stream_id)
        shard_idx = @coordinator.get_shard(stream_id)
        @workers[shard_idx]
      end

      def create_router
        workers = @workers
        coordinator_ractor = @coordinator.ractor

        Ractor.new(workers, coordinator_ractor) do |pool, coord|
          loop do
            msg = Ractor.receive

            case msg
            in [:append, stream_id, event, reply_port]
              # coordinatorに問い合わせ
              coord_port = Ractor::Port.new
              coord.send([:get_shard, stream_id, coord_port])
              shard_idx = coord_port.receive

              event_id = event.respond_to?(:id) ? event.id : SecureRandom.uuid_v7
              event_type = event.class.name
              data = serialize_event(event)

              pool[shard_idx].send([:append, stream_id, event_id, event_type, data, reply_port])

            in [:read_stream, stream_id, reply_port]
              coord_port = Ractor::Port.new
              coord.send([:get_shard, stream_id, coord_port])
              shard_idx = coord_port.receive

              # 生データを受け取ってそのまま返す
              worker_port = Ractor::Port.new
              pool[shard_idx].send([:read_stream, stream_id, worker_port])
              rows = worker_port.receive
              events = rows.map { |event_type, data| deserialize_event(event_type, data) }
              reply_port.send(events)

            in [:stream_size, stream_id, reply_port]
              coord_port = Ractor::Port.new
              coord.send([:get_shard, stream_id, coord_port])
              shard_idx = coord_port.receive

              pool[shard_idx].send([:stream_size, stream_id, reply_port])
            end
          end
        end
      end

      def serialize_event(event)
        members = event.class.members
        hash = members.each_with_object({}) do |key, h|
          h[key] = event.send(key)
        end
        JSON.generate(hash)
      end

      def deserialize_event(event_type, json_data)
        klass = Object.const_get(event_type)
        data = JSON.parse(json_data, symbolize_names: true)
        klass.new(**data)
      end
    end
  end
end

# Ractor内で使うためのグローバル関数
def serialize_event(event)
  members = event.class.members
  hash = members.each_with_object({}) do |key, h|
    h[key] = event.send(key)
  end
  JSON.generate(hash)
end

def deserialize_event(event_type, json_data)
  klass = Object.const_get(event_type)
  data = JSON.parse(json_data, symbolize_names: true)
  klass.new(**data)
end
