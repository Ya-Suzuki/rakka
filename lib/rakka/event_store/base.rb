# frozen_string_literal: true

require "json"
require "securerandom"

module Rakka
  module EventStore
    class Base
      attr_reader :coordinator

      def ractor
        raise NotImplementedError
      end

      def append(stream_id, event)
        raise NotImplementedError
      end

      def read_stream(stream_id)
        raise NotImplementedError
      end

      def stream_size(stream_id)
        raise NotImplementedError
      end

      def release(stream_id)
        @coordinator&.release(stream_id)
      end

      def stats
        @coordinator&.stats
      end

      protected

      def serialize_event(event)
        members = event.class.members
        hash = members.each_with_object({}) do |key, h|
          h[key] = event.send(key)
        end
        JSON.generate(hash)
      end

      def deserialize_event(event_type, json_data)
        klass = Object.const_get(event_type)
        data = JSON.parse(json_data, symbolize_names: true)
        klass.new(**data)
      end
    end
  end
end
