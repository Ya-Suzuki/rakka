# frozen_string_literal: true

module Rakka
  module EventStore
    class Memory
      attr_reader :ractor

      def initialize
        @ractor = Ractor.new do
          streams = {}

          loop do
            msg = Ractor.receive

            case msg
            in [:append, stream_id, event, reply_port]
              streams[stream_id] ||= []
              streams[stream_id] << event
              reply_port.send(:ok)

            in [:read_stream, stream_id, reply_port]
              events = streams[stream_id] || []
              reply_port.send(events)

            in [:stream_size, stream_id, reply_port]
              size = (streams[stream_id] || []).size
              reply_port.send(size)
            end
          end
        end
      end

      def append(stream_id, event)
        port = Ractor::Port.new
        @ractor.send([:append, stream_id, event, port])
        port.receive
      end

      def read_stream(stream_id)
        port = Ractor::Port.new
        @ractor.send([:read_stream, stream_id, port])
        port.receive
      end

      def stream_size(stream_id)
        port = Ractor::Port.new
        @ractor.send([:stream_size, stream_id, port])
        port.receive
      end
    end
  end
end
