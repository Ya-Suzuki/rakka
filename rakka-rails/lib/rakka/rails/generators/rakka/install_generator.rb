# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module Rakka
  module Generators
    class InstallGenerator < ::Rails::Generators::Base
      include ::Rails::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Install Rakka: create migration and initializer"

      def self.next_migration_number(dirname)
        ::ActiveRecord::Generators::Base.next_migration_number(dirname)
      end

      # create_migration という名前にすると、migration_template が内部で呼ぶ
      # Rails::Generators::Migration#create_migration を上書きしてしまう
      def create_migration_files
        migration_template(
          "create_rakka_events.rb.erb",
          "db/migrate/create_rakka_events.rb"
        )
        migration_template(
          "create_rakka_snapshots.rb.erb",
          "db/migrate/create_rakka_snapshots.rb"
        )
      end

      def create_initializer
        template(
          "rakka.rb.erb",
          "config/initializers/rakka.rb"
        )
      end

      def show_readme
        say ""
        say "Rakka installed successfully!", :green
        say ""
        say "Next steps:"
        say "  1. Run migrations: rails db:migrate"
        say "  2. Define your aggregates in app/aggregates/"
        say "  3. Subscribe to events in config/initializers/rakka.rb"
        say ""
      end
    end
  end
end
