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
  #
  # リバランスに調整用の設定は無い。各シャードが実測した「メッセージ1件の処理時間」と
  # 「アクター1つの復元時間」を使い、ワークスティーリングと同じ考え方で決める:
  # 手が空くシャードがあり、そこへ移したほうがそのアクターの処理が早く終わる場合に
  # だけ移す。全シャードが忙しいときは移しても得が無いので何もしない。
  # 調べる間隔も、偏りがある間は短く、無ければ長くなる。
  class ActorSystem
    # 負荷を調べる間隔（秒）の範囲。偏りがある間は最短で、無ければ倍々で延ばす
    REBALANCE_INTERVAL = (0.01..0.5)
    # アクター1つを移すのにかかる固定の手間（秒）の見積もり。復元時間に足して使う
    HANDOFF_OVERHEAD = 0.001

    # ホーム以外に置いているアクターの数の上限。超えたら古いものからホームに戻す
    MAX_ROUTES = 10_000

    attr_reader :event_store, :shard_count

    # snapshot_every: 何イベントごとに状態のスナップショットを保存するか。nil で保存しない
    # rebalance: false でリバランスしない
    def initialize(event_store:, shard_count: Etc.nprocessors, passivate_after: 300,
                   max_actors_per_shard: 10_000, throughput: 5, mailbox_capacity: nil,
                   snapshot_every: 100,
                   rebalance: true,
                   max_restarts: 3, within: 60,
                   publisher_port: Rakka.publisher_port)
      @event_store = event_store
      @shard_count = shard_count

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
                      throughput: throughput, mailbox_capacity: mailbox_capacity,
                      snapshot_every: snapshot_every)
        end
      end

      @running = true
      @stop_signal = Thread::Queue.new
      @timers = [every([[passivate_after / 2.0, 5].min, 0.05].max) { tick }]
      @timers << start_rebalancer if rebalance && shard_count > 1
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

    def start_rebalancer
      Thread.new do
        interval = REBALANCE_INTERVAL.min

        loop do
          @stop_signal.pop(timeout: interval)
          break if @stop_signal.closed?

          imbalanced = begin
            rebalance
          rescue Error
            false
          end
          interval = imbalanced ? REBALANCE_INTERVAL.min : [interval * 2, REBALANCE_INTERVAL.max].min
        end
      end
    end

    # 最も溜まっているシャードから最も空いているシャードへアクターを移す。
    # 溜まり具合は件数ではなく「捌き切るまでの見込み時間」（未処理数 × 1件の処理時間）で比べる。
    # 移す価値のある偏りが残っていれば true を返す（次もすぐ調べる）
    def rebalance
      loads = shard_count.times.filter_map do |index|
        [index, call_shard(index) { |port| [:load, port] }]
      rescue ShardUnavailable
        nil
      end
      send_home_oldest

      measured = loads.filter_map { |_, load| load[:service_time] }
      return false if loads.size < 2 || measured.empty?

      # まだ1件も処理していないシャードは、他のシャードの平均で見積もる
      typical = measured.sum / measured.size
      drain_time = ->(load) { load[:queued] * (load[:service_time] || typical) }

      _, busiest = loads.max_by { |_, load| drain_time.call(load) }
      idlest, idle = loads.min_by { |_, load| drain_time.call(load) }
      gap = drain_time.call(busiest) - drain_time.call(idle)
      per_message = busiest[:service_time] || typical
      cost = HANDOFF_OVERHEAD + (idle[:activation_time] || busiest[:activation_time] || 0)
      return false unless gap > cost

      # 移動が済む頃にも手が空いていないシャードには移さない。どのシャードも忙しいときに
      # 移すと、移動の手間のぶんだけ全体が遅くなる
      return true unless drain_time.call(idle) <= cost

      busiest[:backlog].sort_by { |_, size| -size }.each do |stream_id, size|
        time = size * per_message
        # 移した先で「自分の分 + 移動の手間」をかけても、今のシャードで待つより早く
        # 終わるときだけ移す。1つのアクターに集中している場合は gap ≒ time なので動かない
        next unless gap - time > cost && migrate(stream_id, idlest)

        gap -= 2 * time
      end

      true
    end

    # 移動済みアクターの表が大きくなりすぎないよう、古いものからホームに戻す
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
