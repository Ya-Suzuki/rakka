# frozen_string_literal: true

module Rakka
  class PersistentActor
    attr_reader :id, :state

    def initialize(id, event_store: Rakka.event_store)
      @id = id
      @event_store = event_store
      @state = initial_state
      recover
    end

    # サブクラスでオーバーライド: 初期状態
    def initial_state
      {}
    end

    # サブクラスでオーバーライド: イベント適用
    def apply(event)
      raise NotImplementedError, "#{self.class}#apply must be implemented"
    end

    private

    # イベントを永続化して状態に適用
    def persist(event)
      @event_store.append(stream_id, event)
      apply(event)
    end

    # 過去のイベントを再生して状態を復元
    def recover
      events = @event_store.read_stream(stream_id)
      events.each { |event| apply(event) }
    end

    # ストリームID（Actor識別子）
    def stream_id
      "#{self.class.name}-#{@id}"
    end
  end
end
