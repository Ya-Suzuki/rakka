# frozen_string_literal: true

module Rakka
  # Ractor#monitor でRactorの異常終了を検知して作り直す。
  # ActorSystemがシャードRactorの監視に使う。
  #
  #   supervisor = Rakka::Supervisor.new(max_restarts: 3, within: 60).start
  #   supervisor.supervise(:worker) { Ractor.new { ... } }
  #   supervisor[:worker]  # => 現在のRactor（リスタート後は新しいもの）
  class Supervisor
    Child = Struct.new(:factory, :ractor, :port, :restarts)

    # on_crash: ->(key, dead_ractor) 異常終了を検知するたびに呼ばれる
    def initialize(max_restarts: 3, within: 60, on_crash: nil)
      @max_restarts = max_restarts
      @within = within
      @on_crash = on_crash

      @children = {}
      @mutex = Mutex.new
      @wakeup = Ractor::Port.new
      @running = false
    end

    def start
      @running = true
      @monitor_thread = Thread.new { monitor_loop }
      self
    end

    # 監視だけを止める（子Ractorの停止は呼び出し側の責任）
    def stop
      @running = false
      @wakeup.send(:wake)
      @monitor_thread&.join
      @mutex.synchronize { @children.clear }
    end

    # ブロックは子Ractorを作って返す。リスタート時にも同じブロックが呼ばれる
    def supervise(key, &factory)
      ractor = @mutex.synchronize do
        return @children[key].ractor if @children[key]

        child = Child.new(factory, nil, nil, [])
        spawn(child)
        @children[key] = child
        child.ractor
      end
      @wakeup.send(:wake)
      ractor
    end

    # 現在のRactor。リスタート上限に達して諦めた場合は nil
    def [](key)
      @mutex.synchronize { @children[key]&.ractor }
    end

    def children
      @mutex.synchronize do
        @children.transform_values { |child| { restart_count: child.restarts.size } }
      end
    end

    private

    def spawn(child)
      child.ractor = child.factory.call
      child.port = Ractor::Port.new
      child.ractor.monitor(child.port)
    end

    def monitor_loop
      while @running
        ports = @mutex.synchronize { @children.each_value.map(&:port) }
        port, message = Ractor.select(@wakeup, *ports)
        next if port.equal?(@wakeup)

        handle_exit(port, message)
      end
    end

    def handle_exit(port, message)
      key = dead = nil

      @mutex.synchronize do
        key, child = @children.find { |_, c| c.port.equal?(port) }
        return unless child

        dead = child.ractor
        port.close

        if message != :aborted
          # 正常終了（[:stop] など）は再起動しない
          @children.delete(key)
          return
        end

        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        child.restarts.reject! { |t| now - t > @within }

        if child.restarts.size >= @max_restarts
          warn "[Supervisor] #{key} exceeded max restarts (#{@max_restarts} within #{@within}s), giving up"
          @children.delete(key)
        else
          child.restarts << now
          warn "[Supervisor] #{key} crashed, restarting (#{child.restarts.size}/#{@max_restarts})"
          begin
            spawn(child)
          rescue => e
            warn "[Supervisor] Failed to restart #{key}: #{e.message}"
            @children.delete(key)
          end
        end
      end

      @on_crash&.call(key, dead)
    end
  end
end
