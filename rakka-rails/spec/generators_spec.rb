# frozen_string_literal: true

require "rails/generators"

RSpec.describe "Rakka generators" do
  before(:all) { Rails.application.load_generators }

  around do |example|
    Dir.mktmpdir("rakka-rails-generated") do |dir|
      @destination = dir
      example.run
    end
  end

  def generate(name, *args)
    Rails::Generators.invoke(name, args, destination_root: @destination, behavior: :invoke, quiet: true)
  end

  def generated(pattern)
    Dir[File.join(@destination, pattern)]
  end

  it "installs the migrations and the initializer" do
    generate("rakka:install")

    events = generated("db/migrate/*_create_rakka_events.rb")
    snapshots = generated("db/migrate/*_create_rakka_snapshots.rb")
    expect(events.size).to eq(1)
    expect(snapshots.size).to eq(1)
    expect(File.read(snapshots.first)).to include("create_table :rakka_snapshots")

    initializer = File.read(File.join(@destination, "config/initializers/rakka.rb"))
    Rakka::Rails::SETTINGS.each { |name| expect(initializer).to include("#{name}:") }
  end

  it "generates an aggregate" do
    generate("rakka:aggregate", "bank_account")

    source = File.read(File.join(@destination, "app/aggregates/bank_account.rb"))
    expect(source).to include("class BankAccount < Rakka::PersistentActor")
    expect { RubyVM::InstructionSequence.compile(source) }.not_to raise_error
  end
end
