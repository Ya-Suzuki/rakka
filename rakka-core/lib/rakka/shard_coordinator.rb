# frozen_string_literal: true

module Rakka
  class ShardCoordinator
    attr_reader :ractor

    def initialize(shard_count:)
      @shard_count = shard_count

      @ractor = Ractor.new(shard_count) do |count|
        assignments = {}  # stream_id => shard_index
        load = Array.new(count, 0)  # 各shardの負荷カウント

        loop do
          case Ractor.receive
          in [:get_shard, stream_id, reply_port]
            # 既に割り当て済みならそれを返す
            if assignments.key?(stream_id)
              reply_port.send(assignments[stream_id])
            else
              # 最も負荷の低いshardに割り当て
              min_idx = load.each_with_index.min_by(&:first).last
              assignments[stream_id] = min_idx
              load[min_idx] += 1
              reply_port.send(min_idx)
            end

          in [:release, stream_id, reply_port]
            if (idx = assignments.delete(stream_id))
              load[idx] -= 1
            end
            reply_port.send(:ok)

          in [:stats, reply_port]
            reply_port.send({
              assignments: assignments.dup,
              load: load.dup
            })
          end
        end
      end
    end

    def get_shard(stream_id)
      port = Ractor::Port.new
      @ractor.send([:get_shard, stream_id, port])
      port.receive
    end

    def release(stream_id)
      port = Ractor::Port.new
      @ractor.send([:release, stream_id, port])
      port.receive
    end

    def stats
      port = Ractor::Port.new
      @ractor.send([:stats, port])
      port.receive
    end
  end
end
