# frozen_string_literal: true

module Rakka
  module Rails
    class Configuration
      attr_accessor :pool_size, :database_config_name

      def initialize
        @pool_size = 5
        @database_config_name = :primary
      end

      # ActiveRecordのdatabase.ymlから接続設定を借りる
      def database_options
        ar_config = ActiveRecord::Base.configurations.configs_for(
          env_name: ::Rails.env,
          name: database_config_name.to_s
        )

        raise "Database configuration '#{database_config_name}' not found" unless ar_config

        config = ar_config.configuration_hash

        {
          host: config[:host] || "localhost",
          port: config[:port] || 5432,
          dbname: config[:database],
          user: config[:username],
          password: config[:password]
        }.compact
      end

      def build_event_store
        Rakka::EventStore::Postgres.new(
          pool_size: pool_size,
          **database_options
        )
      end
    end

    class << self
      def configuration
        @configuration ||= Configuration.new
      end

      def configure
        yield(configuration)
      end
    end
  end
end
