# frozen_string_literal: true

module Rakka
  module Rails
    class Railtie < ::Rails::Railtie
      config.rakka = ActiveSupport::OrderedOptions.new

      # 設定の反映は after_initialize で行う。config/initializers/rakka.rb は
      # Railtieのinitializerより後に読まれるので、それより前に読むと反映されない。
      #
      # ここではコネクションもRactorも作らない。ActorSystem（シャードRactor）は
      # 最初のコマンドで起動するので、Pumaのクラスタモードでもfork後の各ワーカーが
      # 自分のシャードを持つ。ワーカー間の同時書き込みは楽観ロックで検出される
      config.after_initialize do |app|
        settings = app.config.rakka

        if settings.fetch(:auto_configure, true)
          Rakka::Rails.apply(settings)

          ::Rails.logger&.info "[Rakka] EventStore configured (#{Rakka.configuration.shard_count} shards per process)"
        end

        # イベントハンドラ（読みモデルの更新など）はRakkaのスレッドで呼ばれる。
        # executorで包み、DB接続の返却とコードの再読み込みとの排他をRailsに任せる
        Rakka.event_bus.around_publish { |publish| app.executor.wrap { publish.call } }

        # コードを再読み込みすると集約クラスは作り直されるが、シャードが持っている
        # アクターは古いクラスのまま残り、次のコマンドが必ず失敗する。再読み込みの前に
        # ActorSystemを止め、次のコマンドで作り直す（アクターの状態はイベントから戻る）
        app.reloader.before_class_unload { Rakka.shutdown }
      end

      generators do
        require_relative "generators/rakka/install_generator"
        require_relative "generators/rakka/aggregate_generator"
      end

      # スキーマ作成用のRakeタスク
      rake_tasks do
        namespace :rakka do
          desc "Create Rakka tables (events and snapshots) if they do not exist"
          task create_schema: :environment do
            Rakka::EventStore::Postgres.create_schema(
              **Rakka::Rails.configuration.database_options
            )
            puts "Created rakka_events and rakka_snapshots tables"
          end

          desc "Show Rakka configuration"
          task info: :environment do
            config = Rakka.configuration
            database = Rakka::Rails.configuration.database_options

            puts "Rakka Configuration:"
            puts "  Database: #{database[:dbname]} (#{database[:host]})"
            Rakka::Rails::SETTINGS.each do |name|
              puts "  #{name}: #{config.public_send(name).inspect}"
            end
          end
        end
      end
    end
  end
end
