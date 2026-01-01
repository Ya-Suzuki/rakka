# frozen_string_literal: true

module Rakka
  class PersistentActor
    attr_reader :id

    def initialize(id, event_store: Rakka.event_store)
      @id = id
      @stream_id = "#{self.class.name}-#{id}"

      # 復元
      initial = initial_state
      past_events = event_store.read_stream(@stream_id)
      recovered_state = past_events.reduce(initial) do |state, event|
        apply_event(event, state)
      end

      # Ractor起動
      @ractor = Ractor.new(self, event_store.ractor, @stream_id, recovered_state) do |actor, store, stream_id, state|
        loop do
          msg = Ractor.receive

          case msg
          in [:command, command, reply_port]
            result = actor.handle(command, state)

            case result
            in [:persist, event]
              # EventStoreに保存（Port経由で返答を待つ）
              store_reply = Ractor::Port.new
              store.send([:append, stream_id, event, store_reply])
              store_reply.receive  # :ok

              state = actor.apply_event(event, state)
              reply_port&.send([:ok, event])

            in [:reject, reason]
              reply_port&.send([:rejected, reason])

            in [:noop]
              reply_port&.send([:noop])
            end

          in [:get_state, reply_port]
            reply_port.send(state)
          end
        end
      end
    end

    # サブクラスでオーバーライド
    def initial_state
      {}
    end

    # サブクラスでオーバーライド
    def handle(command, state)
      raise NotImplementedError
    end

    # サブクラスでオーバーライド
    def apply_event(event, state)
      raise NotImplementedError
    end

    def state
      port = Ractor::Port.new
      @ractor.send([:get_state, port])
      port.receive
    end

    protected

    # 非同期（fire & forget）
    def send_command(command)
      @ractor.send([:command, command, nil])
    end

    # 同期（結果を待つ）
    def send_command_sync(command)
      port = Ractor::Port.new
      @ractor.send([:command, command, port])
      port.receive
    end
  end
end
