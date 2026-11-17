# frozen_string_literal: true

require "securerandom"
require_relative "../../../lib/rakka"
require_relative "../../support/test_actors"

# PostgreSQLが必要（docker compose up -d）。接続できなければスキップする
RSpec.describe "Rakka::EventStore::Postgres" do
  before(:all) do
    Rakka::EventStore::Postgres.create_schema(**Rakka.configuration.postgres_options)
    @available = true
  rescue LoadError, StandardError => e
    @skip_reason = "PostgreSQL is not available: #{e.class}"
  end

  before { skip @skip_reason unless @available }

  let(:store) { Rakka::EventStore::Postgres.new }
  let(:stream_id) { "Counter-#{id}" }
  let(:id) { SecureRandom.hex(8) }

  it "appends and reads events in order" do
    store.append(stream_id, Counter::Incremented[1])
    store.append(stream_id, Counter::Incremented[2])

    expect(store.read_stream(stream_id)).to eq([Counter::Incremented[1], Counter::Incremented[2]])
    expect(store.read_stream(stream_id, from_version: 1)).to eq([Counter::Incremented[2]])
    expect(store.stream_size(stream_id)).to eq(2)
  end

  it "rejects an append with a stale expected_version" do
    store.append(stream_id, Counter::Incremented[1])

    expect { store.append(stream_id, Counter::Incremented[2], expected_version: 0) }
      .to raise_error(Rakka::ConcurrencyError)
    expect(store.stream_size(stream_id)).to eq(1)
  end

  describe "snapshots" do
    it "round-trips the state as Ruby objects" do
      state = { count: 3, last: Counter::Incremented[2], tags: %i[a b] }
      store.save_snapshot(stream_id, 3, state)

      expect(store.snapshot(stream_id)).to eq([1, 3, state])
      expect(store.snapshot("Counter-missing-#{id}")).to be_nil
    end

    it "does not replace a snapshot with an older one" do
      store.save_snapshot(stream_id, 10, { count: 10 })
      store.save_snapshot(stream_id, 5, { count: 5 })

      expect(store.snapshot(stream_id)).to eq([1, 10, { count: 10 }])
    end

    it "restores an actor from the snapshot" do
      system = Rakka::ActorSystem.new(event_store: store, shard_count: 1, snapshot_every: 3)
      actor = Counter.new(id, system: system)
      4.times { actor.increment(1) }
      expect(store.snapshot(stream_id)).to eq([1, 3, { count: 3 }])

      store.save_snapshot(stream_id, 3, { count: 1000 })
      actor.stop

      expect(actor.count).to eq(1001)
    ensure
      system&.stop
    end
  end

  it "keeps a stream consistent when two systems write to it concurrently" do
    # 2つのActorSystem = 同じストリームを別々にキャッシュする2つのプロセス（Pumaワーカー）相当
    limit = LimitedCounter::LIMIT
    systems = Array.new(2) { Rakka::ActorSystem.new(event_store: store, shard_count: 1) }
    stream = "LimitedCounter-#{id}"

    results = systems.map do |system|
      Thread.new do
        actor = LimitedCounter.new(id, system: system)
        Array.new(limit) do
          actor.increment(1).first
        rescue Rakka::ConcurrencyError
          :conflict
        end
      end
    end.flat_map(&:value)

    # 上限(10)を超える書き込みは、どちらのシステム経由でも通らない
    expect(results.count(:ok)).to eq(store.stream_size(stream))
    expect(store.stream_size(stream)).to be <= limit
    expect(store.read_stream(stream).sum(&:amount)).to be <= limit
    expect(LimitedCounter.new(id, system: systems.first).count).to eq(store.stream_size(stream))
  ensure
    systems&.each(&:stop)
  end
end
