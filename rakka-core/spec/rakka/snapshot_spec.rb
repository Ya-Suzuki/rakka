# frozen_string_literal: true

require_relative "../../lib/rakka"
require_relative "../support/test_actors"

RSpec.describe "Rakka snapshots" do
  let(:event_store) { Rakka::EventStore::Memory.new }
  let(:system) { Rakka::ActorSystem.new(event_store: event_store, shard_count: 1, snapshot_every: 3) }

  after do
    system.stop
    event_store.close
  end

  def counter(id, klass = Counter) = klass.new(id, system: system)

  it "saves the state every N events" do
    actor = counter("a")
    2.times { actor.increment(1) }
    expect(event_store.snapshot("Counter-a")).to be_nil

    actor.increment(1)
    expect(event_store.snapshot("Counter-a")).to eq([1, 3, { count: 3 }])

    4.times { actor.increment(1) }
    expect(event_store.snapshot("Counter-a")).to eq([1, 6, { count: 6 }])
  end

  it "counts every event when a command persists several" do
    counter("a").increment_twice(1)
    counter("a").increment_twice(1)

    expect(event_store.snapshot("Counter-a")).to eq([1, 4, { count: 4 }])
  end

  it "restores from the snapshot and replays only the events after it" do
    actor = counter("a")
    4.times { actor.increment(1) } # version 3 でスナップショット、その後に1イベント

    # スナップショットから始めていることを、中身を書き換えて確かめる
    event_store.save_snapshot("Counter-a", 3, { count: 1000 })
    actor.stop

    expect(actor.count).to eq(1001)
  end

  it "keeps taking snapshots after restoring from one" do
    actor = counter("a")
    4.times { actor.increment(1) }
    actor.stop
    2.times { actor.increment(1) } # 復元時点の version 3 から数えて3件目

    expect(event_store.snapshot("Counter-a")).to eq([1, 6, { count: 6 }])
  end

  it "ignores a snapshot written under another schema version" do
    actor = counter("a", MigratedCounter)
    2.times { actor.increment(1) }
    event_store.save_snapshot("MigratedCounter-a", 2, { count: 1000 }, schema: 1)
    actor.stop

    expect(actor.count).to eq(2) # イベントを最初から再生する

    actor.increment(1)
    expect(event_store.snapshot("MigratedCounter-a")).to eq([2, 3, { count: 3 }])
  end

  it "lets a class choose its own interval" do
    2.times { counter("a", FrequentCounter).increment(1) }

    expect(event_store.snapshot("FrequentCounter-a")).to eq([1, 2, { count: 2 }])
  end

  it "lets a class opt out" do
    actor = counter("a", NoSnapshotCounter)
    5.times { actor.increment(1) }
    expect(event_store.snapshot("NoSnapshotCounter-a")).to be_nil

    event_store.save_snapshot("NoSnapshotCounter-a", 5, { count: 1000 })
    actor.stop
    expect(actor.count).to eq(5) # 保存済みのものがあっても使わない
  end

  it "takes no snapshots when disabled" do
    system = Rakka::ActorSystem.new(event_store: event_store, shard_count: 1, snapshot_every: nil)
    200.times { Counter.new("b", system: system).increment(1) }

    expect(event_store.snapshot("Counter-b")).to be_nil
  ensure
    system.stop
  end

  it "does not replace a snapshot with an older one" do
    event_store.save_snapshot("s", 10, { count: 10 })
    event_store.save_snapshot("s", 5, { count: 5 })

    expect(event_store.snapshot("s")).to eq([1, 10, { count: 10 }])
  end
end
