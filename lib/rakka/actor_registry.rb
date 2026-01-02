# frozen_string_literal: true

module Rakka
  class ActorRegistry
    def initialize(passivate_after: 30)
      @passivate_after = passivate_after
      @actors = {}  # actor_key => { actor:, last_active: }
      @mutex = Mutex.new

      start_passivation_checker
    end

    def get_or_create(actor_class, id, **options)
      key = actor_key(actor_class, id)

      @mutex.synchronize do
        entry = @actors[key]

        if entry && entry[:actor]
          entry[:last_active] = Time.now
          return entry[:actor]
        end

        # 新規作成 or 再活性化
        actor = actor_class.new(id, **options)
        @actors[key] = { actor: actor, last_active: Time.now }
        actor
      end
    end

    def touch(actor_class, id)
      key = actor_key(actor_class, id)
      @mutex.synchronize do
        if @actors[key]
          @actors[key][:last_active] = Time.now
        end
      end
    end

    def passivate(actor_class, id)
      key = actor_key(actor_class, id)
      @mutex.synchronize do
        entry = @actors.delete(key)
        entry[:actor].stop if entry && entry[:actor].respond_to?(:stop)
      end
    end

    def stats
      @mutex.synchronize do
        {
          active_count: @actors.size,
          actors: @actors.map do |key, entry|
            {
              key: key,
              idle_seconds: (Time.now - entry[:last_active]).round(1)
            }
          end
        }
      end
    end

    def stop
      @running = false
      @checker_thread&.join
      @mutex.synchronize do
        @actors.each do |_key, entry|
          entry[:actor].stop if entry[:actor].respond_to?(:stop)
        end
        @actors.clear
      end
    end

    private

    def actor_key(actor_class, id)
      "#{actor_class.name}-#{id}"
    end

    def start_passivation_checker
      @running = true
      @checker_thread = Thread.new do
        while @running
          sleep 5  # 5秒ごとにチェック

          now = Time.now
          to_passivate = []

          @mutex.synchronize do
            @actors.each do |key, entry|
              idle_time = now - entry[:last_active]
              if idle_time > @passivate_after
                to_passivate << [key, entry]
              end
            end

            to_passivate.each do |key, entry|
              @actors.delete(key)
              # stopは別スレッドで実行（mutexの外）
            end
          end

          to_passivate.each do |_key, entry|
            entry[:actor].stop if entry[:actor].respond_to?(:stop)
          end
        end
      end
    end
  end
end
