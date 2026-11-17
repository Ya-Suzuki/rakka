# frozen_string_literal: true

require "securerandom"

class RailsAccount < Rakka::PersistentActor
  Deposit = Data.define(:amount)
  Deposited = Data.define(:amount)

  def initial_state = { balance: 0 }
  def deposit(amount) = send_command_sync(Deposit[amount])
  def balance = state[:balance]

  def handle(command, _state)
    case command
    in Deposit(amount:) then [:persist, Deposited[amount]]
    end
  end

  def apply_event(event, state)
    case event
    in Deposited(amount:) then state.merge(balance: state[:balance] + amount)
    end
  end
end

RSpec.describe Rakka::Rails::Railtie do
  it "applies the settings from config/initializers/rakka.rb" do
    expect(Rakka.configuration).to have_attributes(
      shard_count: 2,
      throughput: 7,
      mailbox_capacity: 50,
      snapshot_every: nil, # false = 無効
      rebalance: false
    )
  end

  it "leaves unspecified settings at Rakka's defaults" do
    expect(Rakka.configuration).to have_attributes(passivate_after: 300.0, max_actors_per_shard: 10_000)
  end

  it "builds the event store from the Active Record database configuration" do
    expect(Rakka.event_store).to be_a(Rakka::EventStore::Postgres)
    expect(Rakka.event_store.connector.options).to include(
      host: "localhost", port: 5432, dbname: "rakka_development", user: "rakka"
    )
  end

  it "runs an aggregate end to end" do
    begin
      Rakka::EventStore::Postgres.create_schema(**Rakka::Rails.configuration.database_options)
    rescue PG::Error => e
      skip "PostgreSQL is not available: #{e.class}"
    end

    account = RailsAccount.new(SecureRandom.hex(8))
    account.deposit(100)
    account.deposit(50)

    expect(account.balance).to eq(150)
    expect(Rakka.system.stats).to include(shard_count: 2)
  end
end

RSpec.describe "Rakka in a Rails process" do
  it "runs event handlers inside the Rails executor" do
    inside = Queue.new
    Rakka.subscribe(RailsAccount::Deposited) { inside << Rails.application.executor.active? }

    Rakka.event_bus.publish(RailsAccount::Deposited[1], {})

    expect(inside.pop(timeout: 1)).to be(true)
  ensure
    Rakka.event_bus.clear
  end

  it "restarts the actor system when code is reloaded" do
    store = Rakka::EventStore::Memory.new
    Rakka.configure { |c| c.event_store = store }
    before = Rakka.system

    Rails.application.reloader.new.class_unload! {} # 再読み込み直前に走るコールバック

    expect(Rakka.system).not_to equal(before)
  ensure
    Rakka.shutdown
    Rakka.configure { |c| c.event_store = Rakka::Rails.configuration.build_event_store }
  end
end
