# frozen_string_literal: true

module Rakka
  class EventPublisher
    attr_reader :port

    def initialize(event_bus: Rakka.event_bus)
      @event_bus = event_bus
      @port = Ractor::Port.new
      @running = false
    end

    def start
      @running = true
      @worker = Thread.new do
        while @running
          begin
            message = @port.receive
            case message
            in [:publish, event, metadata]
              @event_bus.publish(event, metadata)
            in [:stop]
              break
            end
          rescue Ractor::ClosedError
            break
          rescue => e
            warn "[EventPublisher] Error: #{e.message}"
          end
        end
      end
      self
    end

    def stop
      @running = false
      @port.send([:stop]) rescue nil
      @worker&.join(1)
    end
  end

  class << self
    def event_publisher
      @event_publisher ||= EventPublisher.new.start
    end

    def publisher_port
      event_publisher.port
    end
  end
end
