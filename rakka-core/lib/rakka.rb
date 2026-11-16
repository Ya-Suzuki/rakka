# frozen_string_literal: true

require "etc"
require_relative "rakka/version"

module Rakka
  class Error < StandardError; end

  # 期待したバージョンとストリームの実バージョンが食い違った（他のライターが先に書いた）
  class ConcurrencyError < Error; end

  # handle / apply_event が例外を投げた。アクターのメモリ上の状態は破棄済みで、
  # 次のコマンドでイベントから再構築される
  class ActorCrashed < Error; end

  # シャードRactorが落ちた、または停止している
  class ShardUnavailable < Error; end

  class Configuration
    attr_accessor :event_store

    # ActorSystem settings
    attr_writer :shard_count, :passivate_after, :max_actors_per_shard

    # PostgreSQL EventStore settings
    attr_writer :postgres_host, :postgres_port,
                :postgres_database, :postgres_user, :postgres_password

    # シャードRactorの数。アクター数とは無関係で、並列度（≒コア数）を決める
    def shard_count
      @shard_count || ENV.fetch("RAKKA_SHARD_COUNT", Etc.nprocessors).to_i
    end

    # この秒数コマンドが来なかったアクターをメモリから解放する
    def passivate_after
      @passivate_after || ENV.fetch("RAKKA_PASSIVATE_AFTER", 300).to_f
    end

    # 1シャードがメモリに保持するアクター数の上限（超えたらLRUで解放）
    def max_actors_per_shard
      @max_actors_per_shard || ENV.fetch("RAKKA_MAX_ACTORS_PER_SHARD", 10_000).to_i
    end

    def postgres_host
      @postgres_host || ENV.fetch("RAKKA_POSTGRES_HOST", "localhost")
    end

    def postgres_port
      @postgres_port || ENV.fetch("RAKKA_POSTGRES_PORT", 5432).to_i
    end

    def postgres_database
      @postgres_database || ENV.fetch("RAKKA_POSTGRES_DATABASE", "rakka_development")
    end

    def postgres_user
      @postgres_user || ENV.fetch("RAKKA_POSTGRES_USER", "rakka")
    end

    def postgres_password
      @postgres_password || ENV.fetch("RAKKA_POSTGRES_PASSWORD", "rakka")
    end

    def postgres_options
      {
        host: postgres_host,
        port: postgres_port,
        dbname: postgres_database,
        user: postgres_user,
        password: postgres_password
      }
    end
  end

  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration)
    end

    def event_store
      configuration.event_store || raise("Rakka.event_store is not configured")
    end

    # デフォルトのActorSystem。初回利用時に起動する（fork後に使い始めれば
    # 各プロセスが自分のシャードRactorを持つ）。event_storeが差し替えられたら作り直す
    def system
      SYSTEM_LOCK.synchronize do
        store = event_store
        if @system && !@system.event_store.equal?(store)
          @system.stop
          @system = nil
        end

        @system ||= ActorSystem.new(
          event_store: store,
          shard_count: configuration.shard_count,
          passivate_after: configuration.passivate_after,
          max_actors_per_shard: configuration.max_actors_per_shard
        )
      end
    end

    def shutdown
      SYSTEM_LOCK.synchronize do
        @system&.stop
        @system = nil
      end
    end
  end

  SYSTEM_LOCK = Mutex.new
  private_constant :SYSTEM_LOCK
end

require_relative "rakka/event_store/base"
require_relative "rakka/event_store/memory"
require_relative "rakka/event_bus"
require_relative "rakka/event_publisher"
require_relative "rakka/supervisor"
require_relative "rakka/shard"
require_relative "rakka/actor_system"
require_relative "rakka/persistent_actor"

module Rakka
  module EventStore
    # pg gem は PostgreSQL を使うときだけ必要
    autoload :Postgres, File.expand_path("rakka/event_store/postgres", __dir__)
  end
end
