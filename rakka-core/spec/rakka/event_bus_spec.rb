# frozen_string_literal: true

require_relative "../../lib/rakka"

RSpec.describe Rakka::EventBus do
  subject(:bus) { described_class.new }

  let(:event) { Data.define(:n) }

  it "calls handlers for the event type and global handlers" do
    calls = []
    bus.subscribe(event) { |e, meta| calls << [:typed, e.n, meta[:v]] }
    bus.subscribe_all { |e, _| calls << [:all, e.n] }

    bus.publish(event[1], { v: 9 })

    expect(calls).to eq([[:typed, 1, 9], [:all, 1]])
  end

  it "keeps calling handlers after one raises" do
    calls = []
    bus.subscribe_all { raise "boom" }
    bus.subscribe_all { calls << :second }

    expect { bus.publish(event[1]) }.to output(/RuntimeError: boom/).to_stderr
    expect(calls).to eq([:second])
  end

  it "wraps the handlers with around_publish" do
    log = []
    bus.subscribe_all { log << :handler }
    bus.around_publish do |publish|
      log << :before
      publish.call
      log << :after
    end

    bus.publish(event[1])

    expect(log).to eq(%i[before handler after])
  end
end
