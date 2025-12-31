# frozen_string_literal: true

module Rakka
  class Configuration
    attr_accessor :event_store
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

require_relative "rakka/event_store/memory"
require_relative "rakka/persistent_actor"
