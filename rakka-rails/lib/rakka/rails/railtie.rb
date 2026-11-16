# frozen_string_literal: true

module Rakka
  module Rails
    class Railtie < ::Rails::Railtie
      config.rakka = ActiveSupport::OrderedOptions.new

      initializer "rakka.configure" do |app|
        # デフォルト設定（未指定の項目はRakka本体のデフォルトに従う）
        Rakka::Rails.configure do |config|
          config.shard_count = app.config.rakka[:shard_count]
          config.passivate_after = app.config.rakka[:passivate_after]
          config.max_actors_per_shard = app.config.rakka[:max_actors_per_shard]
          config.database_config_name = app.config.rakka.fetch(:database_config_name, :primary)
        end
      end

      # ActiveRecordの接続確立後にEventStoreを設定
      #
      # ここではコネクションもRactorも作らない。ActorSystem（シャードRactor）は
      # 最初のコマンドで起動するので、Pumaのクラスタモードでもfork後の各ワーカーが
      # 自分のシャードを持つ。ワーカー間の同時書き込みは楽観ロックで検出される
      config.after_initialize do |app|
        if app.config.rakka.fetch(:auto_configure, true)
          rails_config = Rakka::Rails.configuration

          Rakka.configure do |config|
            config.event_store = rails_config.build_event_store
            config.shard_count = rails_config.shard_count if rails_config.shard_count
            config.passivate_after = rails_config.passivate_after if rails_config.passivate_after
            config.max_actors_per_shard = rails_config.max_actors_per_shard if rails_config.max_actors_per_shard
          end

          ::Rails.logger.info "[Rakka] EventStore configured (#{Rakka.configuration.shard_count} shards per process)"
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
            puts "  Shards per process: #{Rakka.configuration.shard_count}"
            puts "  Database: #{config.database_options[:dbname]}"
            puts "  Host: #{config.database_options[:host]}"
          end
        end
      end
    end
  end
end
