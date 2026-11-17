# frozen_string_literal: true

require "zlib"

module Rakka
  # シャードRactorの集合と、stream_id → シャードのルーティング。
  #
  # Ractorはシャード数（≒コア数）だけ作り、アクターは何個あってもその中に同居する。
  # シャードRactorが落ちたらSupervisorが作り直し、載っていたアクターは
  # 次のコマンドでイベントから復元される。
  class ActorSystem
    attr_reader :event_store, :shard_count

    def initialize(event_store:, shard_count: Etc.nprocessors, passivate_after: 300,
                   max_actors_per_shard: 10_000, throughput: 5, mailbox_capacity: nil,
                   max_restarts: 3, within: 60,
                   publisher_port: Rakka.publisher_port)
      @event_store = event_store
      @shard_count = shard_count

      # 返信待ちのポート => 送信先シャード。シャードが落ちたら待っている側を起こす
      @pending = {}.compare_by_identity
      @pending_lock = Mutex.new

      @supervisor = Supervisor.new(
        max_restarts: max_restarts, within: within, on_crash: method(:fail_pending)
      ).start

      connector = event_store.connector
      shard_count.times do |index|
        @supervisor.supervise(index) do
          Shard.spawn(index, connector, publisher_port,
                      passivate_after: passivate_after, max_actors: max_actors_per_shard,
                      throughput: throughput, mailbox_capacity: mailbox_capacity)
        end
      end

      @running = true
      @stop_signal = Thread::Queue.new
      @ticker = start_ticker([[passivate_after / 2.0, 5].min, 0.05].max)
    end

    # コマンドを送って結果を待つ
    #   => [:ok, event] | [:rejected, reason] | [:noop]
    # handle / apply_event が例外を投げたら ActorCrashed、
    # アクターのメールボックスが満杯なら MailboxFull
    def ask(actor_class, id, command)
      stream_id = actor_class.stream_id(id)

      case call(stream_id) { |port| [:command, actor_class, id, stream_id, command, port] }
      in [:ok | :rejected | :noop, *] => result
        result
      in [:conflict, message]
        raise ConcurrencyError, message
      in [:crashed, error_class, message]
        raise ActorCrashed, "#{stream_id}: #{error_class}: #{message}"
      end
    end

    # コマンドを送るだけ（fire & forget）
    def tell(actor_class, id, command)
      stream_id = actor_class.stream_id(id)
      shard_for(stream_id).send([:command, actor_class, id, stream_id, command, nil])
      nil
    rescue Ractor::ClosedError
      raise ShardUnavailable, "shard for #{stream_id} is not running"
    end

    def state_of(actor_class, id)
      stream_id = actor_class.stream_id(id)

      case call(stream_id) { |port| [:get_state, actor_class, id, stream_id, port] }
      in [:ok, state]
        state
      in [:crashed, error_class, message]
        raise ActorCrashed, "#{stream_id}: #{error_class}: #{message}"
      end
    end

    # メモリ上の状態を今すぐ解放する（イベントは残るので次回アクセスで復元される）
    def passivate(actor_class, id)
      stream_id = actor_class.stream_id(id)
      call(stream_id) { |port| [:passivate, stream_id, port] }
    end

    def stats
      shards = shard_count.times.filter_map do |index|
        next unless (shard = @supervisor[index])

        call_shard(shard) { |port| [:stats, port] }
      rescue ShardUnavailable
        nil
      end

      {
        shard_count: shard_count,
        active_count: shards.sum { |s| s[:active_count] },
        queued: shards.sum { |s| s[:queued] },
        dropped: shards.sum { |s| s[:dropped] },
        restarts: @supervisor.children.transform_values { |c| c[:restart_count] },
        shards: shards
      }
    end

    def stop
      return unless @running

      @running = false
      @stop_signal.push(:stop)
      @ticker.join

      shards = shard_count.times.filter_map { |index| @supervisor[index] }
      shards.each do |shard|
        shard.send([:stop])
      rescue Ractor::ClosedError
        nil
      end
      shards.each do |shard|
        shard.join
      rescue Ractor::Error
        nil
      end

      @supervisor.stop
    end

    def shard_index(stream_id)
      Zlib.crc32(stream_id) % shard_count
    end

    private

    def shard_for(stream_id)
      @supervisor[shard_index(stream_id)] ||
        raise(ShardUnavailable, "shard for #{stream_id} is not running")
    end

    def call(stream_id, &message)
      call_shard(shard_for(stream_id), &message)
    end

    def call_shard(shard)
      port = Ractor::Port.new
      @pending_lock.synchronize { @pending[port] = shard }

      shard.send(yield(port))

      case port.receive
      in [:shard_crashed]
        raise ShardUnavailable, "shard crashed while processing the request"
      in [:mailbox_full, stream_id]
        raise MailboxFull, "#{stream_id}: mailbox is full"
      in reply
        reply
      end
    rescue Ractor::ClosedError
      raise ShardUnavailable, "shard is not running"
    ensure
      @pending_lock.synchronize { @pending.delete(port) }
      port.close
    end

    # 落ちたシャードの返信を待っている呼び出しを起こす
    def fail_pending(_index, dead_shard)
      ports = @pending_lock.synchronize do
        @pending.select { |_, shard| shard.equal?(dead_shard) }.keys
      end

      ports.each do |port|
        port.send([:shard_crashed])
      rescue Ractor::ClosedError
        nil
      end
    end

    def start_ticker(interval)
      Thread.new do
        # stopされるまで interval ごとに起きる
        until @stop_signal.pop(timeout: interval)
          shard_count.times do |index|
            @supervisor[index]&.send([:tick])
          rescue Ractor::ClosedError
            nil
          end
        end
      end
    end
  end
end
