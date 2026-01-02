# frozen_string_literal: true

module Rakka
  module Rails
    class Railtie < ::Rails::Railtie
      config.rakka = ActiveSupport::OrderedOptions.new

      initializer "rakka.configure" do |app|
        # デフォルト設定
        Rakka::Rails.configure do |config|
          config.pool_size = app.config.rakka.fetch(:pool_size, 5)
          config.database_config_name = app.config.rakka.fetch(:database_config_name, :primary)
        end
      end

      # ActiveRecordの接続確立後にEventStoreを設定
      config.after_initialize do |app|
        if app.config.rakka.fetch(:auto_configure, true)
          Rakka.configure do |config|
            config.event_store = Rakka::Rails.configuration.build_event_store
          end

          ::Rails.logger.info "[Rakka] EventStore configured with #{Rakka::Rails.configuration.pool_size} connections"
        end
      end

      # スキーマ作成用のRakeタスク
      rake_tasks do
        namespace :rakka do
          desc "Create Rakka events table"
          task create_schema: :environment do
            Rakka::EventStore::Postgres.create_schema(
              **Rakka::Rails.configuration.database_options
            )
            puts "Created rakka_events table"
          end

          desc "Show Rakka configuration"
          task info: :environment do
            config = Rakka::Rails.configuration
            puts "Rakka Configuration:"
            puts "  Pool size: #{config.pool_size}"
            puts "  Database: #{config.database_options[:dbname]}"
            puts "  Host: #{config.database_options[:host]}"
          end
        end
      end
    end
  end
end
