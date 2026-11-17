# frozen_string_literal: true

require "json"
require "securerandom"

module Rakka
  module EventStore
    # イベント(Data)とJSONの相互変換。どのRactorからでも呼べる
    module Serialization
      module_function

      def dump(event)
        JSON.generate(event.to_h)
      end

      def load(event_type, json_data)
        klass = Object.const_get(event_type)
        klass.new(**JSON.parse(json_data, symbolize_names: true))
      end
    end

    # EventStoreは2つの顔を持つ:
    #
    # - メインRactor用API: append / read_stream / stream_size
    # - connector: Ractor間で共有できるオブジェクト。各シャードRactorが
    #   connector.connect を呼んで自分専用の Journal を得る
    #
    # Journal のインターフェース:
    #   append(stream_id, expected_version, events) => 新しいversion
    #     expected_version が実バージョンと違えば ConcurrencyError
    #     （nil ならチェックなしで末尾に追記）
    #   read(stream_id, from_version = 0) => events
    #   size(stream_id) => version
    #   save_snapshot(stream_id, schema, version, state)
    #     version時点のstateを保存する（ストリームごとに最新の1つだけ持つ）
    #   load_snapshot(stream_id) => [schema, version, state] | nil
    #   close
    #
    # version はストリーム内のイベント数（= 次に書く position）。
    class Base
      def initialize
        @journal_lock = Mutex.new
      end

      def connector
        raise NotImplementedError
      end

      def append(stream_id, event, expected_version: nil)
        journal { |j| j.append(stream_id, expected_version, [event]) }
      end

      def read_stream(stream_id, from_version: 0)
        journal { |j| j.read(stream_id, from_version) }
      end

      def stream_size(stream_id)
        journal { |j| j.size(stream_id) }
      end

      def save_snapshot(stream_id, version, state, schema: 1)
        journal { |j| j.save_snapshot(stream_id, schema, version, state) }
      end

      # => [schema, version, state] | nil
      def snapshot(stream_id)
        journal { |j| j.load_snapshot(stream_id) }
      end

      private

      # メインRactor側のJournal。スレッド間で共有するので直列化する
      def journal
        @journal_lock.synchronize do
          yield(@journal ||= connector.connect)
        end
      end
    end
  end
end
