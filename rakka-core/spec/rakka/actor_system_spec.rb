# frozen_string_literal: true

require_relative "../../lib/rakka"
require_relative "../support/test_actors"

RSpec.describe Rakka::ActorSystem do
  let(:event_store) { Rakka::EventStore::Memory.new }
  let(:options) { {} }
  let(:system) { described_class.new(event_store: event_store, shard_count: 2, **options) }

  after do
    system.stop
    event_store.close
  end

  def counter(id) = Counter.new(id, system: system)

  def eventually(timeout: 3)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise "condition not met within #{timeout}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.01
    end
  end

  describe "lightweight actors" do
    it "hosts many actors on a fixed number of Ractors" do
      system # 起動しておく
      ractors_before = Ractor.count

      1_000.times { |i| counter("c-#{i}").increment(i) }

      expect(Ractor.count).to eq(ractors_before)
      expect(system.stats[:active_count]).to eq(1_000)
      expect(system.stats[:shards].map { |s| s[:active_count] }).to all(be > 0)
      expect(counter("c-42").count).to eq(42)
    end

    it "always routes a stream to the same shard" do
      index = system.shard_index("Counter-a")

      expect(index).to be_between(0, 1)
      expect(Array.new(10) { system.shard_index("Counter-a") }).to all(eq(index))
    end
  end

  describe "commands" do
    it "returns the persisted event" do
      expect(counter("a").increment(5)).to eq([:ok, Counter::Incremented[5]])
    end

    it "persists several events from one command atomically" do
      result = counter("a").increment_twice(3)

      expect(result).to eq([:ok, [Counter::Incremented[3], Counter::Incremented[3]]])
      expect(counter("a").count).to eq(6)
      expect(event_store.stream_size("Counter-a")).to eq(2)
    end

    it "returns noop without persisting" do
      expect(counter("a").increment(0)).to eq([:noop])
      expect(event_store.stream_size("Counter-a")).to eq(0)
    end

    it "processes async commands in order" do
      actor = counter("a")
      (1..10).each { |i| actor.increment_async(i) }

      expect(actor.count).to eq(55) # 同じシャードのメールボックスに並ぶので、stateの問い合わせは後になる
      expect(event_store.read_stream("Counter-a").map(&:amount)).to eq((1..10).to_a)
    end
  end

  describe "mailboxes" do
    let(:port) { Ractor::Port.new }
    let(:system) do
      described_class.new(event_store: event_store, shard_count: 1, throughput: 2, publisher_port: port)
    end

    # シャードを塞いでおき、その間に送ったメッセージが全部メールボックスに溜まった
    # 状態から処理が始まるようにする
    def while_shard_is_busy
      counter("blocker").sleep_async(0.2)
      yield
    end

    def published_actor_ids(count)
      Array.new(count) { port.receive.last[:actor_id] }
    end

    it "does not let a busy actor starve the others" do
      while_shard_is_busy do
        6.times { counter("busy").increment_async }
        counter("other").increment_async
      end

      # busyに6件溜まっていても、2件(throughput)処理したところでotherに順番が回る
      expect(published_actor_ids(7)).to eq(%w[busy busy other busy busy busy busy])
    end

    it "takes turns between actors that both have a backlog" do
      while_shard_is_busy do
        4.times { counter("a").increment_async }
        4.times { counter("b").increment_async }
      end

      expect(published_actor_ids(8)).to eq(%w[a a b b a a b b])
    end

    it "keeps each actor's messages in arrival order" do
      while_shard_is_busy do
        (1..7).each { |i| counter("a").increment_async(i) }
        (1..7).each { |i| counter("b").increment_async(i * 10) }
      end

      expect(counter("a").count).to eq(28)
      expect(event_store.read_stream("Counter-a").map(&:amount)).to eq((1..7).to_a)
      expect(event_store.read_stream("Counter-b").map(&:amount)).to eq((1..7).map { |i| i * 10 })
    end

    it "reports the backlog in stats" do
      counter("blocker").sleep_async(0.3)
      sleep 0.05 # blockerの処理が始まるのを待つ
      3.times { counter("a").increment_async }

      # statsはシャード宛てなので、次の振り分けのタイミングで（aの処理より前に）答えが返る
      expect(system.stats).to include(queued: 3)
      expect(counter("a").count).to eq(3)
      expect(system.stats).to include(queued: 0)
    end

    it "finishes queued messages before stopping" do
      while_shard_is_busy do
        5.times { counter("a").increment_async }
      end
      system.stop

      expect(event_store.stream_size("Counter-a")).to eq(5)
    end
  end

  describe "event publishing" do
    it "publishes persisted events with metadata" do
      port = Ractor::Port.new
      system = described_class.new(event_store: event_store, shard_count: 1, publisher_port: port)

      Counter.new("a", system: system).increment_twice(2)

      expect(port.receive).to eq([:publish, Counter::Incremented[2],
                                  { stream_id: "Counter-a", actor_id: "a", version: 1 }])
      expect(port.receive.last[:version]).to eq(2)
    ensure
      system.stop
    end
  end

  describe "actor crash (let it crash)" do
    let(:system) { described_class.new(event_store: event_store, shard_count: 1) }

    it "raises ActorCrashed to the caller" do
      expect { counter("a").crash! }.to raise_error(Rakka::ActorCrashed, /Counter-a: RuntimeError: boom/)
    end

    it "discards only the crashed actor and recovers it from events" do
      counter("a").increment(10)
      counter("b").increment(20)

      expect { counter("a").crash! }.to raise_error(Rakka::ActorCrashed)

      stats = system.stats[:shards].first
      expect(stats).to include(active_count: 1, crashes: 1) # bは同じシャードで生きたまま
      expect(counter("b").count).to eq(20)
      expect(counter("a").count).to eq(10)
      expect(counter("a").increment(1)).to eq([:ok, Counter::Incremented[1]])
    end
  end

  describe "optimistic concurrency" do
    it "re-evaluates the command against fresh state when another writer got in first" do
      actor = LimitedCounter.new("a", system: system)
      actor.increment(4)

      # 別プロセスのライターを模して、アクターを通さずに直接書く
      event_store.append("LimitedCounter-a", LimitedCounter::Incremented[5])

      # キャッシュ(4)のままなら通ってしまうが、読み直した状態(9)では上限超え
      expect(actor.increment(2)).to eq([:rejected, :limit_exceeded])
      expect(actor.increment(1)).to eq([:ok, LimitedCounter::Incremented[1]])
      expect(actor.count).to eq(10)
      expect(event_store.stream_size("LimitedCounter-a")).to eq(3)
    end
  end

  describe "passivation" do
    context "when idle" do
      let(:options) { { passivate_after: 0.1 } }

      it "releases idle actors and rehydrates them on demand" do
        counter("a").increment(7)
        expect(system.stats[:active_count]).to eq(1)

        eventually { system.stats[:active_count].zero? }

        expect(counter("a").count).to eq(7)
      end
    end

    context "when over capacity" do
      let(:system) { described_class.new(event_store: event_store, shard_count: 1, max_actors_per_shard: 3) }

      it "evicts the least recently used actor" do
        %w[a b c].each { |id| counter(id).increment(1) }
        counter("a").count # aを使う → 最も古いのはb
        counter("d").increment(1)

        expect(system.stats[:active_count]).to eq(3)
        expect(counter("b").count).to eq(1) # 追い出されてもイベントから戻る
      end
    end

    it "passivates explicitly via #stop" do
      actor = counter("a")
      actor.increment(3)
      actor.stop

      expect(system.stats[:active_count]).to eq(0)
      expect(actor.count).to eq(3)
    end
  end

  describe "shard crash" do
    let(:system) { described_class.new(event_store: event_store, shard_count: 1, max_restarts: 2, within: 60) }

    it "wakes the waiting caller and restarts the shard" do
      counter("a").increment(10)

      expect { counter("a").kill_shard! }.to raise_error(Rakka::ShardUnavailable)

      eventually { system.stats[:restarts] == { 0 => 1 } }
      expect(counter("a").count).to eq(10)
      expect(counter("a").increment(1)).to eq([:ok, Counter::Incremented[1]])
    end

    it "gives up after max_restarts" do
      3.times do
        expect { counter("a").kill_shard! }.to raise_error(Rakka::ShardUnavailable)
        sleep 0.1
      end

      expect { counter("a").count }.to raise_error(Rakka::ShardUnavailable)
    end
  end
end
