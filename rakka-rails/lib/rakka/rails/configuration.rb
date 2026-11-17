# frozen_string_literal: true

module Rakka
  module Rails
    # config.rakka のうち、そのまま Rakka.configure に渡す項目
    SETTINGS = %i[
      shard_count passivate_after max_actors_per_shard throughput
      mailbox_capacity snapshot_every rebalance
    ].freeze

    class Configuration
      attr_accessor :database_config_name

      def initialize
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
        Rakka::EventStore::Postgres.new(**database_options)
      end
    end

    class << self
      def configuration
        @configuration ||= Configuration.new
      end

      def configure
        yield(configuration)
      end

      # config.rakka（Hash / OrderedOptions）の内容を Rakka 本体の設定に反映する。
      # 指定の無い項目は Rakka 本体のデフォルトのまま。false は「無効」として渡す
      def apply(settings)
        configuration.database_config_name = settings.fetch(:database_config_name, :primary)

        Rakka.configure do |config|
          config.event_store = configuration.build_event_store

          SETTINGS.each do |name|
            value = settings[name]
            config.public_send("#{name}=", value) unless value.nil?
          end
        end
      end
    end
  end
end
