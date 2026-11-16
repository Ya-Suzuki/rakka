# frozen_string_literal: true

require_relative "../../../lib/rakka"

RSpec.describe Rakka::EventStore::Memory do
  subject(:store) { described_class.new }

  let(:event) { Data.define(:n) }

  after { store.close }

  it "appends and reads events in order" do
    store.append("s", event[1])
    store.append("s", event[2])

    expect(store.read_stream("s").map(&:n)).to eq([1, 2])
    expect(store.read_stream("s", from_version: 1).map(&:n)).to eq([2])
    expect(store.stream_size("s")).to eq(2)
    expect(store.read_stream("other")).to eq([])
  end

  it "returns the new version" do
    expect(store.append("s", event[1])).to eq(1)
    expect(store.append("s", event[2], expected_version: 1)).to eq(2)
  end

  it "rejects an append with a stale expected_version" do
    store.append("s", event[1])

    expect { store.append("s", event[2], expected_version: 0) }
      .to raise_error(Rakka::ConcurrencyError, /expected version 0, actual 1/)
    expect(store.stream_size("s")).to eq(1)
  end
end
