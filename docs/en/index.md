---
title: Home
nav_order: 1
permalink: /en/
layout: landing
description: State falls away; events make it bloom again. An actor-based event sourcing library for Ruby 4.0 Ractors.
---

```ruby
class BankAccount < Rakka::PersistentActor
  Deposit        = Data.define(:amount)
  MoneyDeposited = Data.define(:amount)

  def initial_state = { balance: 0 }

  # command -> events (decide)
  def handle(command, state)
    case command
    in Deposit(amount:) then [:persist, MoneyDeposited[amount]]
    end
  end

  # events -> state (a pure function)
  def apply_event(event, state)
    case event
    in MoneyDeposited(amount:)
      state.merge(balance: state[:balance] + amount)
    end
  end

  def deposit(amount) = send_command_sync(Deposit[amount])
  def balance = state[:balance]
end

account = BankAccount.new("account-123")
account.deposit(1000)
account.balance # => 1000 (after a restart too: rebuilt from events)
```
