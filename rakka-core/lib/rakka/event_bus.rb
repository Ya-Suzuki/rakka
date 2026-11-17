# frozen_string_literal: true

module Rakka
  class EventBus
    def initialize
      @handlers = Hash.new { |h, k| h[k] = [] }
      @global_handlers = []
      @mutex = Mutex.new
    end

    # 特定イベントタイプのハンドラを登録
    def subscribe(event_class, &block)
      @mutex.synchronize do
        @handlers[event_class.name] << block
      end
    end

    # 全イベントを受け取るハンドラを登録
    def subscribe_all(&block)
      @mutex.synchronize do
        @global_handlers << block
      end
    end

    # ハンドラの呼び出しを包む処理を設定する。ブロックはハンドラ群を呼ぶ proc を受け取る。
    # Railsでは executor で包み、DB接続の返却やコードの再読み込みとの排他を任せる:
    #
    #   bus.around_publish { |publish| Rails.application.executor.wrap { publish.call } }
    def around_publish(&wrapper)
      @wrapper = wrapper
    end

    # イベントを発行
    def publish(event, metadata = {})
      handlers = @mutex.synchronize do
        @handlers[event.class.name] + @global_handlers
      end
      return if handlers.empty?

      run = lambda do
        handlers.each do |handler|
          handler.call(event, metadata)
        rescue => e
          warn "[EventBus] Handler error: #{e.class}: #{e.message}"
        end
      end

      @wrapper ? @wrapper.call(run) : run.call
    end

    # 非同期でイベントを発行（別スレッドで実行）
    def publish_async(event, metadata = {})
      Thread.new { publish(event, metadata) }
    end

    def clear
      @mutex.synchronize do
        @handlers.clear
        @global_handlers.clear
      end
    end
  end

  # グローバルEventBus
  class << self
    def event_bus
      @event_bus ||= EventBus.new
    end

    def subscribe(event_class, &block)
      event_bus.subscribe(event_class, &block)
    end

    def subscribe_all(&block)
      event_bus.subscribe_all(&block)
    end

    def publish(event, metadata = {})
      event_bus.publish(event, metadata)
    end
  end
end
