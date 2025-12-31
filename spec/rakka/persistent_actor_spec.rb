# frozen_string_literal: true

require_relative "../../lib/rakka"
require_relative "../../examples/bank_account"

RSpec.describe Rakka::PersistentActor do
  let(:event_store) { Rakka::EventStore::Memory.new }

  before do
    Rakka.configure { |c| c.event_store = event_store }
  end

  describe BankAccount do
    subject(:account) { BankAccount.new("test-account") }

    describe "#initial_state" do
      it "starts with zero balance" do
        expect(account.balance).to eq(0)
      end
    end

    describe "#deposit" do
      it "increases balance" do
        account.deposit(BankAccount::Deposit[500])

        expect(account.balance).to eq(500)
      end

      it "persists event" do
        account.deposit(BankAccount::Deposit[500])

        events = event_store.read_stream("BankAccount-test-account")
        expect(events.size).to eq(1)
        expect(events.first).to eq(BankAccount::MoneyDeposited[500])
      end
    end

    describe "#withdraw" do
      before { account.deposit(BankAccount::Deposit[1000]) }

      it "decreases balance" do
        account.withdraw(BankAccount::Withdraw[300])

        expect(account.balance).to eq(700)
      end

      it "raises error when insufficient funds" do
        expect {
          account.withdraw(BankAccount::Withdraw[2000])
        }.to raise_error(BankAccount::InsufficientFunds)
      end

      it "does not change balance when rejected" do
        begin
          account.withdraw(BankAccount::Withdraw[2000])
        rescue BankAccount::InsufficientFunds
        end

        expect(account.balance).to eq(1000)
      end
    end

    describe "recovery" do
      it "restores state from events" do
        account.deposit(BankAccount::Deposit[1000])
        account.withdraw(BankAccount::Withdraw[300])

        recovered = BankAccount.new("test-account")

        expect(recovered.balance).to eq(700)
      end
    end
  end
end
