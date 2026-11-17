# frozen_string_literal: true

require_relative "base"

module Rakka
  module EventStore
    # テスト用。1つのRactorが全ストリームを保持し、各Journalはメッセージで読み書きする
    class Memory < Base
      Connector = Data.define(:ractor) do
        def connect
          Journal.new(ractor)
        end
      end

      class Journal
        def initialize(ractor)
          @ractor = ractor
        end

        def append(stream_id, expected_version, events)
          case call(:append, stream_id, expected_version, events)
          in [:ok, version]
            version
          in [:conflict, actual]
            raise ConcurrencyError,
                  "#{stream_id}: expected version #{expected_version}, actual #{actual}"
          end
        end

        def read(stream_id, from_version = 0)
          call(:read, stream_id, from_version)
        end

        def size(stream_id)
          call(:size, stream_id)
        end

        def save_snapshot(stream_id, schema, version, state)
          call(:save_snapshot, stream_id, schema, version, state)
        end

        def load_snapshot(stream_id)
          call(:load_snapshot, stream_id)
        end

        def recover(stream_id, schema)
          call(:recover, stream_id, schema)
        end

        def close; end

        private

        def call(*message)
          port = Ractor::Port.new
          @ractor.send([*message, port])
          port.receive
        ensure
          port&.close
        end
      end

      attr_reader :connector

      def initialize
        super()

        ractor = Ractor.new do
          streams = Hash.new { |h, k| h[k] = [] }
          snapshots = {}

          loop do
            case Ractor.receive
            in [:append, stream_id, expected_version, events, reply]
              stream = streams[stream_id]
              if expected_version && expected_version != stream.size
                reply.send([:conflict, stream.size])
              else
                stream.concat(events)
                reply.send([:ok, stream.size])
              end

            in [:read, stream_id, from_version, reply]
              stream = streams.fetch(stream_id, [])
              reply.send(stream.drop(from_version))

            in [:size, stream_id, reply]
              reply.send(streams.fetch(stream_id, []).size)

            in [:save_snapshot, stream_id, schema, version, state, reply]
              current = snapshots[stream_id]
              snapshots[stream_id] = [schema, version, state] if !current || current[1] <= version
              reply.send(:ok)

            in [:load_snapshot, stream_id, reply]
              reply.send(snapshots[stream_id])

            in [:recover, stream_id, schema, reply]
              stream = streams.fetch(stream_id, [])
              snapshot_schema, version, state = snapshots[stream_id]
              if schema && snapshot_schema == schema
                reply.send([version, state, stream.drop(version)])
              else
                reply.send([0, nil, stream])
              end

            in [:stop]
              break
            end
          end
        end

        @connector = Connector.new(ractor)
      end

      def close
        @connector.ractor.send([:stop])
      rescue Ractor::ClosedError
        nil
      end
    end
  end
end
