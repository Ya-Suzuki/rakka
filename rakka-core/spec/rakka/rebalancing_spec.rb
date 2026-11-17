# frozen_string_literal: true

require "timeout"
require_relative "../../lib/rakka"
require_relative "../support/test_actors"

RSpec.describe "Rakka::ActorSystem rebalancing" do
  let(:event_store) { Rakka::EventStore::Memory.new }
  let(:options) { { rebalance: false } }
  let(:system) { Rakka::ActorSystem.new(event_store: event_store, shard_count: 2, **options) }

  after do
    system.stop
    event_store.close
  end

  def counter(id) = Counter.new(id, system: system)
  def stream(id) = "Counter-#{id}"
  def amounts(id) = event_store.read_stream(stream(id)).map(&:amount)

  # ホームが指定のシャードになるID
  def ids_on(index, count)
    (1..).lazy.map { |i| "c#{i}" }.select { |id| system.home_index(stream(id)) == index }.first(count)
  end

  def eventually(timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise "condition not met within #{timeout}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.01
    end
  end

  describe "#migrate" do
    let(:id) { ids_on(0, 1).first }
    let(:blocker) { ids_on(0, 2).last }

    it "moves an actor to another shard and back" do
      counter(id).increment(5)

      expect(system.migrate(stream(id), 1)).to be(true)
      expect(system.shard_index(stream(id))).to eq(1)
      expect(counter(id).count).to eq(5)
      expect(counter(id).increment(1)).to eq([:ok, Counter::Incremented[1]])
      expect(system.stats).to include(migrations: 1, relocated: 1)
      expect(system.stats[:shards].map { |s| s[:active_count] }).to eq([0, 1])

      expect(system.migrate(stream(id), 0)).to be(true)
      expect(system.shard_index(stream(id))).to eq(0)
      expect(counter(id).count).to eq(6)
      expect(system.stats).to include(migrations: 2, relocated: 0)
    end

    it "does nothing when the actor is already there" do
      expect(system.migrate(stream(id), 0)).to be(false)
      expect(system.stats).to include(migrations: 0)
    end

    it "hands the backlog over and keeps the message order" do
      counter(blocker).sleep_async(0.2) # シャード0を塞ぎ、idのメッセージを溜める
      (1..10).each { |i| counter(id).increment_async(i) }

      system.migrate(stream(id), 1)
      (11..15).each { |i| counter(id).increment_async(i) } # 引き継ぎが届くまでシャード1で保留される

      expect(counter(id).count).to eq((1..15).sum)
      expect(amounts(id)).to eq((1..15).to_a)
      expect(system.stats[:shards][1]).to include(processed: 15)
    end

    it "answers a caller whose request was handed over" do
      counter(blocker).sleep_async(0.2)
      waiting = Thread.new { counter(id).increment(7) }
      sleep 0.05

      system.migrate(stream(id), 1)

      expect(waiting.value).to eq([:ok, Counter::Incremented[7]])
    end

    it "does not strand the actor when the source shard crashes before handing over" do
      counter(blocker).sleep_then_kill_shard_async(0.2)
      sleep 0.05
      system.migrate(stream(id), 1)

      result = Timeout.timeout(3) { counter(id).increment(1) }

      expect(result).to eq([:ok, Counter::Incremented[1]])
    end

    it "wakes handed-over callers when the target shard has crashed" do
      target_blocker = ids_on(1, 1).first
      # 時系列: 0.1s migrate → 0.25s 移動先が落ちる → 0.5s 移動元が手放す
      counter(target_blocker).sleep_then_kill_shard_async(0.25)
      counter(blocker).sleep_async(0.5)
      sleep 0.05
      waiting = Thread.new do
        Thread.current.report_on_exception = false
        counter(id).increment(7)
      end
      sleep 0.05

      system.migrate(stream(id), 1) # シャード0が手放す頃には、移動先のRactorはもう居ない

      expect { Timeout.timeout(3) { waiting.value } }.to raise_error(Rakka::ShardUnavailable)
      expect(counter(id).increment(1)).to eq([:ok, Counter::Incremented[1]]) # 再起動後のシャード1で動く
    end
  end

  describe "automatic rebalancing" do
    let(:options) { {} }

    it "moves backlogged actors from a busy shard to an idle one" do
      ids = ids_on(0, 8)
      ids.each { |id| (1..15).each { |i| counter(id).slow_increment_async(i, 0.01) } }

      eventually { ids.all? { |id| event_store.stream_size(stream(id)) == 15 } }

      stats = system.stats
      expect(stats[:migrations]).to be > 0
      expect(stats[:shards][1][:processed]).to be > 0
      ids.each { |id| expect(amounts(id)).to eq((1..15).to_a) } # 移動しても順序は保たれる
    end

    it "finishes sooner than a single shard could" do
      ids = ids_on(0, 8)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      ids.each { |id| 15.times { counter(id).slow_increment_async(1, 0.01) } }
      eventually { ids.all? { |id| event_store.stream_size(stream(id)) == 15 } }
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(elapsed).to be < 1.0 # 1シャードで順に処理すると 120件 × 10ms = 1.2秒
    end

    it "does not move actors when the backlog is too short to be worth it" do
      ids = ids_on(0, 8)
      ids.each { |id| counter(id).increment_async } # すぐ終わる処理が1件ずつ

      eventually { ids.all? { |id| event_store.stream_size(stream(id)) == 1 } }
      sleep 0.1

      expect(system.stats).to include(migrations: 0)
    end

    it "leaves a single hot actor where it is" do
      id = ids_on(0, 1).first
      (1..30).each { |i| counter(id).slow_increment_async(i, 0.005) }

      eventually { event_store.stream_size(stream(id)) == 30 }

      expect(system.stats).to include(migrations: 0)
    end

    it "sends the oldest relocated actors home when too many are relocated" do
      stub_const("Rakka::ActorSystem::MAX_ROUTES", 1)
      first, second = ids_on(0, 2)
      system.migrate(stream(first), 1)
      system.migrate(stream(second), 1)

      eventually { system.stats[:relocated] == 1 }

      expect(system.shard_index(stream(first))).to eq(0)
      expect(system.shard_index(stream(second))).to eq(1)
    end
  end
end
