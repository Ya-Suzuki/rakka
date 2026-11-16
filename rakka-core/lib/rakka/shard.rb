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
  #   [:stop]              溜まっているメッセージを処理し終えてから止まる
  class Shard
    Entry = Struct.new(:behavior, :state, :version, :last_active)

    # 自分宛てに送る目印。これを受け取るまでに届いていた分は振り分け済みと分かる
    DRAINED = :__rakka_drained__

    # 楽観ロック競合時に、状態を読み直してコマンドをやり直す回数
    MAX_CONFLICT_RETRIES = 3

    # behaviorの例外でアクター1つだけを落とす範囲。これ以外（Exception直下など）は
    # シャードRactorごと落ち、Supervisorが再起動する
    ACTOR_ERRORS = [StandardError, ScriptError].freeze

    def self.spawn(index, connector, publisher_port, passivate_after:, max_actors:, throughput:)
      Ractor.new(index, connector, publisher_port, passivate_after, max_actors, throughput,
                 name: "rakka-shard-#{index}") do |i, conn, publisher, idle, max, slice|
        Rakka::Shard.new(i, conn.connect, publisher,
                         passivate_after: idle, max_actors: max, throughput: slice).run
      end
    end

    def initialize(index, journal, publisher_port, passivate_after:, max_actors:, throughput:)
      @index = index
      @journal = journal
      @publisher = publisher_port
      @passivate_after = passivate_after
      @max_actors = max_actors
      @throughput = throughput

      # stream_id => 未処理メッセージ。空になったら消すので、ここにあるアクター =
      # 実行待ちのアクター。挿入順がそのまま実行順（ランキュー）になる
      @mailboxes = {}
      @queued = 0
      @stopping = false

      # stream_id => Entry。挿入順 = 最後に使われた順（先頭が最も古い）
      @actors = {}
      @processed = 0
      @crashes = 0
    end

    def run
      until @stopping && @mailboxes.empty?
        if @mailboxes.empty?
          dispatch(Ractor.receive) # 仕事が無いので届くまで待つ
        else
          drain
          run_next_actor
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
        enqueue(stream_id, message)
      in [:passivate, stream_id, _]
        enqueue(stream_id, message)
      in [:tick]
        passivate_idle
      in [:stats, reply]
        respond(reply, { index: @index, active_count: @actors.size, queued: @queued,
                         processed: @processed, crashes: @crashes })
      in [:stop]
        @stopping = true
      end
    end

    def enqueue(stream_id, message)
      (@mailboxes[stream_id] ||= []) << message
      @queued += 1
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

        case message
        in [:command, actor_class, id, _, command, reply]
          on_command(actor_class, id, stream_id, command, reply)
        in [:get_state, actor_class, id, _, reply]
          on_get_state(actor_class, id, stream_id, reply)
        in [:passivate, _, reply]
          @actors.delete(stream_id)
          respond(reply, :ok)
        end
      end

      @mailboxes[stream_id] = mailbox unless mailbox.empty?
    end

    def on_command(actor_class, id, stream_id, command, reply)
      attempts = 0

      begin
        entry = activate(actor_class, id, stream_id)

        case entry.behavior.handle(command, entry.state)
        in [:persist, *events] unless events.empty?
          persist(entry, id, stream_id, events)
          respond(reply, [:ok, events.size == 1 ? events.first : events])
        in [:reject, reason]
          respond(reply, [:rejected, reason])
        in [:noop]
          respond(reply, [:noop])
        end

        @processed += 1
      rescue ConcurrencyError => e
        # 他のライター（別プロセスなど）が先に書いた。キャッシュした状態を捨て、
        # 最新のイベントから作り直してコマンドを判定し直す
        @actors.delete(stream_id)
        retry if (attempts += 1) <= MAX_CONFLICT_RETRIES
        respond(reply, [:conflict, e.message])
      rescue *ACTOR_ERRORS => e
        crash(stream_id, e, reply)
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
    end

    # メモリ上のアクターを返す。無ければイベントを再生して作る（再活性化）
    def activate(actor_class, id, stream_id)
      entry = @actors.delete(stream_id)

      unless entry
        behavior = actor_class.behavior(id)
        events = @journal.read(stream_id)
        state = events.reduce(behavior.initial_state) { |s, event| behavior.apply_event(event, s) }
        entry = Entry.new(behavior, state, events.size, nil)

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
