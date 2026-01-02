# frozen_string_literal: true

module Rakka
  class Configuration
    attr_accessor :event_store

    # PostgreSQL EventStore settings
    attr_writer :postgres_pool_size, :postgres_host, :postgres_port,
                :postgres_database, :postgres_user, :postgres_password

    def postgres_pool_size
      @postgres_pool_size || ENV.fetch("RAKKA_POSTGRES_POOL_SIZE", 5).to_i
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
  end
end

require_relative "rakka/shard_coordinator"
require_relative "rakka/event_store/base"
require_relative "rakka/event_store/memory"
require_relative "rakka/event_store/postgres"
require_relative "rakka/persistent_actor"
