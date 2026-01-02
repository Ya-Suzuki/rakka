# frozen_string_literal: true

require "rails/generators"

module Rakka
  module Generators
    class AggregateGenerator < ::Rails::Generators::NamedBase
      source_root File.expand_path("templates", __dir__)

      desc "Generate a Rakka aggregate"

      def create_aggregate_file
        template(
          "aggregate.rb.erb",
          "app/aggregates/#{file_name}.rb"
        )
      end

      def create_aggregates_directory
        empty_directory "app/aggregates" unless File.directory?("app/aggregates")
      end

      private

      def class_name
        name.camelize
      end

      def file_name
        name.underscore
      end
    end
  end
end
