# frozen_string_literal: true

module Rakka
  module EventStore
    class Memory
      def initialize
        @streams = {}
      end

      # イベントを追記
      def append(stream_id, event)
        @streams[stream_id] ||= []
        @streams[stream_id] << event
      end

      # ストリームの全イベントを取得
      def read_stream(stream_id)
        @streams[stream_id] || []
      end

      # ストリームのイベント数
      def stream_size(stream_id)
        read_stream(stream_id).size
      end
    end
  end
end
