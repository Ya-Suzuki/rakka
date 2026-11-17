# frozen_string_literal: true

require "zlib"

module Rakka
  # シャードRactorの集合と、stream_id → シャードのルーティング。
  #
  # Ractorはシャード数（≒コア数）だけ作り、アクターは何個あってもその中に同居する。
  # シャードRactorが落ちたらSupervisorが作り直し、載っていたアクターは
  # 次のコマンドでイベントから復元される。
  #
  # アクターの置き場所は crc32(stream_id) で決まる「ホーム」が基本だが、あるシャードに
  # メッセージが溜まると、溜まっているアクターを空いているシャードへ移す（リバランス）。
  class ActorSystem
    # ホーム以外に置いているアクターの数の上限。超えたら古いものからホームに戻す
    MAX_ROUTES = 10_000

    attr_reader :event_store, :shard_count

    # rebalance_interval: 負荷の偏りを調べる間隔（秒）。nil でリバランスしない
    # rebalance_threshold: シャード間の未処理メッセージ数の差がこれ以上なら移す
    def initialize(event_store:, shard_count: Etc.nprocessors, passivate_after: 300,
                   max_actors_per_shard: 10_000, throughput: 5, mailbox_capacity: nil,
                   rebalance_interval: 1, rebalance_threshold: 50,
                   max_restarts: 3, within: 60,
                   publisher_port: Rakka.publisher_port)
      @event_store = event_store
      @shard_count = shard_count
      @rebalance_threshold = rebalance_threshold

      # ルーティングに関わる状態はすべてこのロックで守る。「送り先を調べて送る」を
      # ロックの中で行うので、アクターの移動と送信の順序が入れ替わらない
      @lock = Mutex.new
      # 返信待ちのポート => 送信先シャード。シャードが落ちたら待っている側を起こす
      @pending = {}.compare_by_identity
      # ホーム以外に置いているアクター: stream_id => シャード番号（古い順）
      @routes = {}
      # 移動中のアクター: stream_id => [移動元のRactor, 移動先のシャード番号]
      @migrating = {}
      @migrations = 0

      @supervisor = Supervisor.new(
        max_restarts: max_restarts, within: within, on_crash: method(:shard_crashed)
      ).start

      # シャード → メインへの連絡口。アクターが他のアクターに送るメッセージと、
      # アクターの引き継ぎ完了の通知がここを通る
      @router_port = Ractor::Port.new
      router_port = @router_port
      @router = Thread.new { route_messages }

      connector = event_store.connector
      shard_count.times do |index|
        @supervisor.supervise(index) do
          Shard.spawn(index, connector, publisher_port, router_port,
                      passivate_after: passivate_after, max_actors: max_actors_per_shard,
                      throughput: throughput, mailbox_capacity: mailbox_capacity)
        end
      end

      @running = true
      @stop_signal = Thread::Queue.new
      @timers = [every([[passivate_after / 2.0, 5].min, 0.05].max) { tick }]
      @timers << every(rebalance_interval) { rebalance } if rebalance_interval && shard_count > 1
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
      @lock.synchronize do
        post(route(stream_id), [:command, actor_class, id, stream_id, command, nil])
      end
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

    # アクターを別のシャードへ移す。未処理のメッセージも一緒に移り、順序は保たれる。
    # 手順:
    #   1. 移動先に [:expect] を送る → 引き継ぎが届くまで、そのアクター宛ては保留する
    #   2. ルートを切り替える → 以降のメッセージは移動先へ（保留される）
    #   3. 移動元に [:release] を送る → 溜まっていたメッセージを移動先に渡す
    #   4. 移動先が [:adopt] を受け取り、引き継いだ分 → 保留していた分の順に処理を再開
    # 移動中、移動先が同じ、シャードが動いていない場合は何もせず false を返す
    def migrate(stream_id, to)
      @lock.synchronize do
        from = route(stream_id)
        source = @supervisor[from]
        target = @supervisor[to]
        return false if from == to || @migrating.key?(stream_id) || !source || !target

        target.send([:expect, stream_id])
        @routes.delete(stream_id)
        @routes[stream_id] = to unless to == home_index(stream_id)
        @migrating[stream_id] = [source, to]
        @migrations += 1

        begin
          source.send([:release, stream_id, target])
        rescue Ractor::ClosedError
          # 移動元がもう居ない。引き継ぐものは無いので、移動先の保留だけ解く
          @migrating.delete(stream_id)
          target.send([:adopt, stream_id, []])
        end

        true
      end
    rescue Ractor::ClosedError
      false
    end

    def stats
      shards = shard_count.times.filter_map do |index|
        call_shard(index) { |port| [:stats, port] }
      rescue ShardUnavailable
        nil
      end
      routes, migrations = @lock.synchronize { [@routes.size, @migrations] }

      {
        shard_count: shard_count,
        active_count: shards.sum { |s| s[:active_count] },
        queued: shards.sum { |s| s[:queued] },
        dropped: shards.sum { |s| s[:dropped] },
        migrations: migrations,
        relocated: routes,
        restarts: @supervisor.children.transform_values { |c| c[:restart_count] },
        shards: shards
      }
    end

    def stop
      return unless @running

      @running = false
      @stop_signal.close
      @timers.each(&:join)

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
      @router_port.send([:stop])
      @router.join
      @router_port.close
    end

    # アクターが今いるシャード
    def shard_index(stream_id)
      @lock.synchronize { route(stream_id) }
    end

    # リバランスで移されていないときのシャード
    def home_index(stream_id)
      Zlib.crc32(stream_id) % shard_count
    end

    private

    # --- 以下2つは @lock を持った状態で呼ぶ ---

    def route(stream_id)
      @routes[stream_id] || home_index(stream_id)
    end

    def post(index, message, reply_port = nil)
      shard = @supervisor[index] || raise(ShardUnavailable, "shard #{index} is not running")
      @pending[reply_port] = shard if reply_port
      shard.send(message)
    end

    def call(stream_id)
      await { |port| @lock.synchronize { post(route(stream_id), yield(port), port) } }
    end

    def call_shard(index)
      await { |port| @lock.synchronize { post(index, yield(port), port) } }
    end

    def await
      port = Ractor::Port.new
      yield port

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
      @lock.synchronize { @pending.delete(port) }
      port.close
    end

    def shard_crashed(index, dead_shard)
      waiting = @lock.synchronize do
        @migrating.delete_if do |stream_id, (source, to)|
          if source.equal?(dead_shard)
            # 引き継ぎを渡す前に移動元が落ちた。移動先の保留を解く
            begin
              @supervisor[to]&.send([:adopt, stream_id, []])
            rescue Ractor::ClosedError
              nil
            end
            true
          else
            to == index # 移動先が落ちた。保留していた分はシャードごと失われている
          end
        end

        @pending.select { |_, shard| shard.equal?(dead_shard) }.keys
      end

      fail_requests(waiting)
    end

    # 落ちたシャードの返信を待っている呼び出しを起こす
    def fail_requests(ports)
      ports.each do |port|
        port.send([:shard_crashed])
      rescue Ractor::ClosedError
        nil
      end
    end

    def route_messages
      loop do
        case @router_port.receive
        in [:tell, actor_class, id, command]
          begin
            tell(actor_class, id, command)
          rescue Error => e
            warn "[Rakka] message to #{actor_class.stream_id(id)} was not delivered: #{e.message}"
          end
        in [:adopted, stream_id, shard, reply_ports]
          adopted(stream_id, shard, reply_ports)
        in [:stop]
          break
        end
      end
    end

    # 引き継ぎ完了。引き継がれたメッセージの返信待ちを、移動先のシャードに付け替える
    def adopted(stream_id, shard, reply_ports)
      orphaned = @lock.synchronize do
        @migrating.delete(stream_id)
        alive = shard_count.times.any? { |index| @supervisor[index].equal?(shard) }
        waiting = reply_ports.select { |port| @pending.key?(port) }

        if alive
          waiting.each { |port| @pending[port] = shard }
          []
        else
          waiting # 通知が届く前に移動先が落ちていた
        end
      end

      fail_requests(orphaned)
    end

    def tick
      shard_count.times do |index|
        @supervisor[index]&.send([:tick])
      rescue Ractor::ClosedError
        nil
      end
    end

    # 最も溜まっているシャードから最も空いているシャードへ、差が縮まる分だけ移す
    def rebalance
      loads = shard_count.times.filter_map do |index|
        [index, call_shard(index) { |port| [:load, port] }]
      rescue ShardUnavailable
        nil
      end
      return if loads.size < 2

      _, busiest = loads.max_by { |_, load| load[:queued] }
      idlest, idle = loads.min_by { |_, load| load[:queued] }
      gap = busiest[:queued] - idle[:queued]

      busiest[:backlog].sort_by { |_, size| -size }.each do |stream_id, size|
        break if gap < @rebalance_threshold
        next if size >= gap # 移しても偏りが逆向きになるだけ（1つのアクターに集中している等）

        gap -= 2 * size if migrate(stream_id, idlest)
      end

      send_home_oldest
    end

    def send_home_oldest
      loop do
        stream_id = @lock.synchronize { @routes.first&.first if @routes.size > MAX_ROUTES }
        break unless stream_id && migrate(stream_id, home_index(stream_id))
      end
    end

    # stopされるまで interval 秒ごとにブロックを実行する
    def every(interval)
      Thread.new do
        loop do
          @stop_signal.pop(timeout: interval)
          break if @stop_signal.closed?

          begin
            yield
          rescue Error => e
            warn "[Rakka] #{e.class}: #{e.message}"
          end
        end
      end
    end
  end
end
