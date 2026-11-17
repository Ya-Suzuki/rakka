# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"
ENV["DATABASE_URL"] ||= "postgres://rakka:rakka@localhost:5432/rakka_development"

require "tmpdir"
require "logger"
require "rails"
require "active_record/railtie"
require "rakka-rails"

# config/initializers/rakka.rb がある最小のRailsアプリ
module Dummy
  ROOT = Dir.mktmpdir("rakka-rails-dummy")
  FileUtils.mkdir_p(File.join(ROOT, "config/initializers"))
  File.write(File.join(ROOT, "config/initializers/rakka.rb"), <<~RUBY)
    Rails.application.config.rakka = {
      shard_count: 2,
      throughput: 7,
      mailbox_capacity: 50,
      snapshot_every: false,
      rebalance: false
    }
  RUBY

  class Application < ::Rails::Application
    config.root = ROOT
    config.eager_load = false
    config.logger = Logger.new(nil)
  end
end

Dummy::Application.initialize!

RSpec.configure do |config|
  config.after(:suite) do
    Rakka.shutdown
    FileUtils.rm_rf(Dummy::ROOT)
  end
end
