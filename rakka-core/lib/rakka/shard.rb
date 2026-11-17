# frozen_string_literal: true

module Rakka
  # 1つのRactorの中で多数のアクターを動かす実行単位。
  #
  # アクターはRactorではなく、このシャードが持つHashの1エントリ
  # （behavior + state + version）でしかない。同じstream_idは必ず同じシャードに
  # 届き、シャードは1メッセージずつ処理するので、アクターごとの直列性が保たれる。
  #
  # メールボックスはアクターごとに持つ。シャードは届いたメッセージをまず宛先の
  # メールボックスに振り分け、メッセージを持つアクターを順番に throughput 件ずつ
  # 処理する（Akkaのディスパッチャと同じ）。1つのアクターにコマンドが溜まっても、
  # 同じシャードの他のアクターは throughput 件ごとに順番が回ってくる。
  #
  # Shardのインスタンスは自分のRactorの中だけで生きる（外からはメッセージで操作する）:
  #
  #   アクター宛て（メールボックスに入り、アクターごとに到着順で処理される）
  #   [:command, actor_class, id, stream_id, command, reply_port | nil]
  #   [:get_state, actor_class, id, stream_id, reply_port]
  #   [:passivate, stream_id, reply_port | nil]
  #
  #   シャード宛て（すぐ処理される）
  #   [:tick]              アイドルなアクターの掃除
  #   [:stats, reply_port]
  #   [:load, reply_port]  リバランス用: 未処理数、実測した処理時間、溜まっているアクターの一覧
  #
  #   アクターの移動（ActorSystem#migrate を参照）
  #   [:expect, stream_id]                 これから引き継ぐ。届くまでこのアクター宛ては保留
  #   [:release, stream_id, target_ractor] 手放す。未処理のメッセージを target に渡す
  #   [:adopt, stream_id, backlog]         引き継ぐ。backlog → 保留分の順に処理を再開
  #   [:stop]              溜まっているメッセージを処理し終えてから止まる
  class Shard
    # snapshot_at: 保存済みの最新スナップショットのversion（無ければ0）
    Entry = Struct.new(:behavior, :state, :version, :last_active, :snapshot_at)

    # リバランスの判断材料として報告するアクター数の上限
    LOAD_SAMPLE = 64

    # 実測値の移動平均で、新しい計測に掛ける重み
    SMOOTHING = 0.2

    # 自分宛てに送る目印。これを受け取るまでに届いていた分は振り分け済みと分かる
    DRAINED = :__rakka_drained__

    # 楽観ロック競合時に、状態を読み直してコマンドをやり直す回数
    MAX_CONFLICT_RETRIES = 3

    # behaviorの例外でアクター1つだけを落とす範囲。これ以外（Exception直下など）は
    # シャードRactorごと落ち、Supervisorが再起動する
    ACTOR_ERRORS = [StandardError, ScriptError].freeze

    # handle の中から他のアクターへ送るメッセージを、コマンドの処理が済むまで預かる。
    # シャードRactor内では PersistentActor のハンドルがこれを送信先として使う
    class Outbox
      def open
        @messages = []
      end

      def close
        messages = @messages
        @messages = nil
        messages
      end

      def tell(actor_class, id, command)
        raise Error, "an actor can send messages only from handle" unless @messages

        @messages << [:tell, actor_class, id, command]
        nil
      end

      # 返信を待つとシャードごと止まり、相手が同じシャードならデッドロックする
      def ask(*)
        raise Error, "an actor cannot wait for another actor (use send_command, not send_command_sync)"
      end
      alias state_of ask
      alias passivate ask
    end

    # options: passivate_after, max_actors, throughput, mailbox_capacity, snapshot_every
    def self.spawn(index, connector, publisher_port, router_port, **options)
      Ractor.new(index, connector, publisher_port, router_port, Ractor.make_shareable(options),
                 name: "rakka-shard-#{index}") do |i, conn, publisher, router, opts|
        Rakka::Shard.new(i, conn.connect, publisher, router, **opts).run
      end
    end

    def initialize(index, journal, publisher_port, router_port, passivate_after:, max_actors:,
                   throughput:, mailbox_capacity: nil, snapshot_every: nil)
      @index = index
      @journal = journal
      @publisher = publisher_port
      @router = router_port
      @outbox = Outbox.new
      @passivate_after = passivate_after
      @max_actors = max_actors
      @throughput = throughput
      @mailbox_capacity = mailbox_capacity
      @snapshot_every = snapshot_every

      # stream_id => 未処理メッセージ。空になったら消すので、ここにあるアクター =
      # 実行待ちのアクター。挿入順がそのまま実行順（ランキュー）になる
      @mailboxes = {}
      @queued = 0
      @dropped = 0
      # リバランスの判断材料にする実測値（秒、移動平均）。まだ測れていなければ nil
      @service_time = nil    # メッセージ1件の処理
      @activation_time = nil # アクター1つの復元
      # 引き継ぎ待ちのアクター: stream_id => 保留中のメッセージ
      @parked = {}
      @stopping = false

      # stream_id => Entry。挿入順 = 最後に使われた順（先頭が最も古い）
      @actors = {}
      @processed = 0
      @crashes = 0
    end

    def run
      Ractor.current[:rakka_context] = @outbox

      until @stopping && @mailboxes.empty?
        if @mailboxes.empty?
          dispatch(Ractor.receive) # 仕事が無いので届くまで待つ
        else
          drain
          run_next_actor unless @mailboxes.empty? # drain中にアクターを手放して空になることがある
        end
      end
    ensure
      @journal.close
    end

    private

    # メッセージをアクターのメールボックスに入れる。シャード宛てはその場で処理する
    def dispatch(message)
      case message
      in [:command | :get_state, _, _, stream_id, *]
        accept(stream_id, message)
      in [:passivate, stream_id, _]
        accept(stream_id, message)
      in [:expect, stream_id]
        @actors.delete(stream_id)
        @parked[stream_id] ||= []
      in [:release, stream_id, target]
        release(stream_id, target)
      in [:adopt, stream_id, backlog]
        adopt(stream_id, backlog)
      in [:load, reply]
        respond(reply, { queued: @queued, service_time: @service_time, activation_time: @activation_time,
                         backlog: @mailboxes.first(LOAD_SAMPLE).map { |id, mailbox| [id, mailbox.size] } })
      in [:tick]
        passivate_idle
      in [:stats, reply]
        respond(reply, { index: @index, active_count: @actors.size, queued: @queued,
                         processed: @processed, crashes: @crashes, dropped: @dropped,
                         service_time: @service_time, activation_time: @activation_time })
      in [:stop]
        @stopping = true
      end
    end

    def accept(stream_id, message)
      if (parked = @parked[stream_id])
        parked << message
      else
        enqueue(stream_id, message)
      end
    end

    # アクターを手放す。メモリ上の状態は捨て（移動先がイベントから復元する）、
    # 未処理のメッセージは順序を保ったまま移動先に渡す
    def release(stream_id, target)
      backlog = @mailboxes.delete(stream_id) || []
      @queued -= backlog.size
      @actors.delete(stream_id)

      target.send([:adopt, stream_id, backlog])
    rescue Ractor::ClosedError
      # 移動先が落ちていた。待っている呼び出しを起こす
      backlog.each { |message| respond(message.last, [:shard_crashed]) }
    end

    def adopt(stream_id, backlog)
      parked = @parked.delete(stream_id) || []
      (backlog + parked).each { |message| enqueue(stream_id, message) }

      @router.send([:adopted, stream_id, Ractor.current, backlog.filter_map(&:last)])
    end

    def enqueue(stream_id, message)
      mailbox = (@mailboxes[stream_id] ||= [])
      return drop(stream_id, message) if @mailbox_capacity && mailbox.size >= @mailbox_capacity

      mailbox << message
      @queued += 1
    end

    # メールボックスが満杯。溜め込まずに断り、送り手に過負荷を伝える
    def drop(stream_id, message)
      @dropped += 1

      if (reply = message.last)
        respond(reply, [:mailbox_full, stream_id])
      else
        warn "[Rakka] #{stream_id} mailbox is full (#{@mailbox_capacity}), message dropped"
      end
    end

    # すでに届いているメッセージを、ブロックせずに全部メールボックスへ振り分ける
    def drain
      Ractor.current.send(DRAINED)
      until (message = Ractor.receive) == DRAINED
        dispatch(message)
      end
    end

    # 先頭のアクターを throughput 件まで処理し、残りがあれば列の最後に回す
    def run_next_actor
      stream_id, mailbox = @mailboxes.shift

      mailbox.shift(@throughput).each do |message|
        @queued -= 1
        started = now

        case message
        in [:command, actor_class, id, _, command, reply]
          on_command(actor_class, id, stream_id, command, reply)
        in [:get_state, actor_class, id, _, reply]
          on_get_state(actor_class, id, stream_id, reply)
        in [:passivate, _, reply]
          @actors.delete(stream_id)
          respond(reply, :ok)
        end

        @service_time = smooth(@service_time, now - started)
      end

      @mailboxes[stream_id] = mailbox unless mailbox.empty?
    end

    def smooth(average, sample)
      average ? average + SMOOTHING * (sample - average) : sample
    end

    def on_command(actor_class, id, stream_id, command, reply)
      attempts = 0

      begin
        entry = activate(actor_class, id, stream_id)

        @outbox.open
        result = entry.behavior.handle(command, entry.state)
        outgoing = @outbox.close

        case result
        in [:persist, *events] unless events.empty?
          persist(entry, id, stream_id, events)
          respond(reply, [:ok, events.size == 1 ? events.first : events])
        in [:reject, reason]
          respond(reply, [:rejected, reason])
        in [:noop]
          respond(reply, [:noop])
        end

        # 他のアクター宛ては、永続化まで成功してから送る。競合でやり直した回や
        # クラッシュした回の分は送られない
        outgoing.each { |message| @router.send(message) }
        @processed += 1
      rescue ConcurrencyError => e
        # 他のライター（別プロセスなど）が先に書いた。キャッシュした状態を捨て、
        # 最新のイベントから作り直してコマンドを判定し直す
        @actors.delete(stream_id)
        retry if (attempts += 1) <= MAX_CONFLICT_RETRIES
        respond(reply, [:conflict, e.message])
      rescue *ACTOR_ERRORS => e
        crash(stream_id, e, reply)
      ensure
        @outbox.close
      end
    end

    def on_get_state(actor_class, id, stream_id, reply)
      respond(reply, [:ok, activate(actor_class, id, stream_id).state])
    rescue *ACTOR_ERRORS => e
      crash(stream_id, e, reply)
    end

    def persist(entry, id, stream_id, events)
      version = @journal.append(stream_id, entry.version, events)

      entry.state = events.reduce(entry.state) { |state, event| entry.behavior.apply_event(event, state) }
      entry.version = version

      events.each_with_index do |event, i|
        @publisher.send([:publish, event, { stream_id: stream_id, actor_id: id,
                                            version: version - events.size + i + 1 }])
      end

      save_snapshot(entry, stream_id)
    end

    # 前回のスナップショットから interval 件以上イベントが増えていたら、今の状態を保存する
    def save_snapshot(entry, stream_id)
      actor_class = entry.behavior.class
      interval = actor_class.snapshot_interval(@snapshot_every)
      return unless interval && entry.version - entry.snapshot_at >= interval

      @journal.save_snapshot(stream_id, actor_class.snapshot_schema_version, entry.version, entry.state)
      entry.snapshot_at = entry.version
    rescue StandardError => e
      # スナップショットは復元を速くするためだけのもの。保存に失敗しても処理は続ける
      warn "[Rakka] #{stream_id} snapshot was not saved: #{e.class}: #{e.message}"
    end

    # メモリ上のアクターを返す。無ければスナップショット + それ以降のイベントから
    # 作る（再活性化）
    def activate(actor_class, id, stream_id)
      entry = @actors.delete(stream_id)

      unless entry
        started = now
        behavior = actor_class.behavior(id)
        # スナップショットを使わないクラスは schema を渡さず、全イベントを読む
        schema = actor_class.snapshot_schema_version if actor_class.snapshot_interval(@snapshot_every)
        snapshot_at, state, events = @journal.recover(stream_id, schema)
        state = behavior.initial_state if snapshot_at.zero?
        state = events.reduce(state) { |s, event| behavior.apply_event(event, s) }
        entry = Entry.new(behavior, state, snapshot_at + events.size, nil, snapshot_at)
        @activation_time = smooth(@activation_time, now - started)

        @actors.shift while @actors.size >= @max_actors
      end

      entry.last_active = now
      @actors[stream_id] = entry
    end

    # let it crash: 状態を捨てるだけ。次のコマンドでイベントから復元される
    def crash(stream_id, error, reply)
      @actors.delete(stream_id)
      @crashes += 1

      if reply
        respond(reply, [:crashed, error.class.name, error.message])
      else
        warn "[Rakka] #{stream_id} crashed: #{error.class}: #{error.message}"
      end
    end

    def passivate_idle
      deadline = now - @passivate_after
      @actors.shift while (oldest = @actors.first) && oldest[1].last_active < deadline
    end

    def respond(port, message)
      port&.send(message)
    rescue Ractor::ClosedError
      nil # 呼び出し側がもう待っていない
    end

    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
