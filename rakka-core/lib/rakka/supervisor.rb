# frozen_string_literal: true

module Rakka
  class Supervisor
    # リスタート戦略
    # :one_for_one - クラッシュしたActorのみ再起動
    # :rest_for_one - クラッシュしたActor以降を全て再起動（未実装）
    # :one_for_all - 全Actor再起動（未実装）

    def initialize(strategy: :one_for_one, max_restarts: 3, within: 60)
      @strategy = strategy
      @max_restarts = max_restarts
      @within = within

      @children = {}  # key => { actor_class:, id:, options:, actor:, port:, restarts: [] }
      @port_to_key = {}  # port => key

      @running = false
      @monitor_thread = nil
      @mutex = Mutex.new
    end

    def start
      @running = true
      start_monitor_loop
      self
    end

    def stop
      @running = false
      @mutex.synchronize do
        @children.each_value do |child|
          child[:actor]&.stop rescue nil
        end
        @children.clear
        @port_to_key.clear
      end
      @monitor_thread&.join
    end

    def supervise(actor_class, id, **options)
      key = actor_key(actor_class, id)

      @mutex.synchronize do
        return @children[key][:actor] if @children[key]

        actor = create_and_monitor(actor_class, id, options, key)
        actor
      end
    end

    def children
      @mutex.synchronize do
        @children.transform_values do |child|
          {
            id: child[:id],
            class: child[:actor_class].name,
            alive: child[:actor]&.alive?,
            restart_count: child[:restarts].size
          }
        end
      end
    end

    private

    def actor_key(actor_class, id)
      "#{actor_class.name}-#{id}"
    end

    def create_and_monitor(actor_class, id, options, key)
      actor = actor_class.new(id, **options)
      port = Ractor::Port.new

      # Ractor内部の@ractorをモニタ
      actor.instance_variable_get(:@ractor).monitor(port)

      @children[key] = {
        actor_class: actor_class,
        id: id,
        options: options,
        actor: actor,
        port: port,
        restarts: []
      }
      @port_to_key[port] = key

      actor
    end

    def start_monitor_loop
      @monitor_thread = Thread.new do
        while @running
          ports = @mutex.synchronize { @port_to_key.keys.dup }

          if ports.empty?
            sleep 0.1
            next
          end

          # タイムアウト付きでselectしたいが、Ractor.selectにtimeoutがないので
          # 別スレッドでタイムアウト用のポートを使う
          timeout_port = Ractor::Port.new
          timeout_thread = Thread.new do
            sleep 0.5
            timeout_port.send(:timeout) rescue nil
          end

          begin
            result = Ractor.select(*ports, timeout_port)
            port, message = result

            if port == timeout_port
              # タイムアウト、ループ継続
              next
            end

            if message == :aborted
              handle_crash(port)
            end
          rescue Ractor::ClosedError
            # ポートが閉じられた（正常停止など）
          ensure
            timeout_thread.kill rescue nil
          end
        end
      end
    end

    def handle_crash(port)
      @mutex.synchronize do
        key = @port_to_key.delete(port)
        return unless key

        child = @children[key]
        return unless child

        now = Time.now

        # 古いリスタート記録を削除
        child[:restarts].reject! { |t| now - t > @within }

        if child[:restarts].size >= @max_restarts
          # リスタート上限到達
          warn "[Supervisor] #{key} exceeded max restarts (#{@max_restarts} within #{@within}s), giving up"
          @children.delete(key)
          return
        end

        # リスタート
        child[:restarts] << now
        warn "[Supervisor] #{key} crashed, restarting (#{child[:restarts].size}/#{@max_restarts})"

        begin
          new_actor = child[:actor_class].new(child[:id], **child[:options])
          new_port = Ractor::Port.new
          new_actor.instance_variable_get(:@ractor).monitor(new_port)

          child[:actor] = new_actor
          child[:port] = new_port
          @port_to_key[new_port] = key
        rescue => e
          warn "[Supervisor] Failed to restart #{key}: #{e.message}"
          @children.delete(key)
        end
      end
    end
  end
end
