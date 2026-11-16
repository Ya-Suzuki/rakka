# frozen_string_literal: true

module Rakka
  # 1つのRactorの中で多数のアクターを動かす実行単位。
  #
  # アクターはRactorではなく、このシャードが持つHashの1エントリ
  # （behavior + state + version）でしかない。同じstream_idは必ず同じシャードに
  # 届き、シャードは1メッセージずつ処理するので、アクターごとの直列性が保たれる。
  #
  # Shardのインスタンスは自分のRactorの中だけで生きる（外からはメッセージで操作する）:
  #
  #   [:command, actor_class, id, stream_id, command, reply_port | nil]
  #   [:get_state, actor_class, id, stream_id, reply_port]
  #   [:passivate, stream_id, reply_port | nil]
  #   [:tick]              アイドルなアクターの掃除
  #   [:stats, reply_port]
  #   [:stop]
  class Shard
    Entry = Struct.new(:behavior, :state, :version, :last_active)

    # 楽観ロック競合時に、状態を読み直してコマンドをやり直す回数
    MAX_CONFLICT_RETRIES = 3

    # behaviorの例外でアクター1つだけを落とす範囲。これ以外（Exception直下など）は
    # シャードRactorごと落ち、Supervisorが再起動する
    ACTOR_ERRORS = [StandardError, ScriptError].freeze

    def self.spawn(index, connector, publisher_port, passivate_after:, max_actors:)
      Ractor.new(index, connector, publisher_port, passivate_after, max_actors,
                 name: "rakka-shard-#{index}") do |i, conn, publisher, idle, max|
        Rakka::Shard.new(i, conn.connect, publisher, passivate_after: idle, max_actors: max).run
      end
    end

    def initialize(index, journal, publisher_port, passivate_after:, max_actors:)
      @index = index
      @journal = journal
      @publisher = publisher_port
      @passivate_after = passivate_after
      @max_actors = max_actors

      # stream_id => Entry。挿入順 = 最後に使われた順（先頭が最も古い）
      @actors = {}
      @processed = 0
      @crashes = 0
    end

    def run
      loop do
        case Ractor.receive
        in [:command, actor_class, id, stream_id, command, reply]
          on_command(actor_class, id, stream_id, command, reply)
        in [:get_state, actor_class, id, stream_id, reply]
          on_get_state(actor_class, id, stream_id, reply)
        in [:passivate, stream_id, reply]
          @actors.delete(stream_id)
          respond(reply, :ok)
        in [:tick]
          passivate_idle
        in [:stats, reply]
          respond(reply, { index: @index, active_count: @actors.size,
                           processed: @processed, crashes: @crashes })
        in [:stop]
          break
        end
      end
    ensure
      @journal.close
    end

    private

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
