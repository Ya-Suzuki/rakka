---
title: Get started
nav_order: 2
---

# Get started
{: .no_toc }

1. TOC
{:toc}

## Requirements

| Item | Requirement |
|---|---|
| Ruby | 4.0 or later (uses `Ractor::Port`) |
| Database | PostgreSQL through the `pg` gem. Drivers that cannot run inside Ractors (`sqlite3`, `mysql2`) are not supported |
| Rails (rakka-rails) | 7.0 or later. The sample app is tested on 8.1 |

Tests and demos can use the in-memory event store, so PostgreSQL is optional.

## Install

Rakka is not on rubygems.org yet, so reference the repository.

```ruby
# Gemfile
gem "rakka", github: "Ya-Suzuki/rakka", glob: "rakka-core/*.gemspec"

# For Rails
gem "rakka-rails", github: "Ya-Suzuki/rakka", glob: "rakka-rails/*.gemspec"
```

## Define an aggregate

Subclass `Rakka::PersistentActor` and write three methods.

| Method | Role |
|---|---|
| `initial_state` | The state before any event |
| `handle(command, state)` | Decides what a command does. Returns `[:persist, event, ...]`, `[:reject, reason]` or `[:noop]` |
| `apply_event(event, state)` | Applies an event and returns the new state (a pure function) |

```ruby
class BankAccount < Rakka::PersistentActor
  # Commands
  Deposit = Data.define(:amount)
  Withdraw = Data.define(:amount)

  # Events
  MoneyDeposited = Data.define(:amount)
  MoneyWithdrawn = Data.define(:amount)

  def initial_state
    { balance: 0 }
  end

  def deposit(amount) = send_command_sync(Deposit[amount])
  def withdraw(amount) = send_command_sync(Withdraw[amount])
  def balance = state[:balance]

  def handle(command, state)
    case command
    in Deposit(amount:)
      [:persist, MoneyDeposited[amount]]
    in Withdraw(amount:) if state[:balance] < amount
      [:reject, :insufficient_funds]
    in Withdraw(amount:)
      [:persist, MoneyWithdrawn[amount]]
    end
  end

  def apply_event(event, state)
    case event
    in MoneyDeposited(amount:)
      state.merge(balance: state[:balance] + amount)
    in MoneyWithdrawn(amount:)
      state.merge(balance: state[:balance] - amount)
    end
  end
end
```

{: .important }
Define commands and events with `Data.define`: they are immutable values that can be passed between Ractors. `handle` and `apply_event` run inside a shard Ractor, so touch nothing but their arguments (no globals, no Active Record).

## Configure

```ruby
Rakka.configure do |c|
  # In memory (for tests)
  c.event_store = Rakka::EventStore::Memory.new

  # PostgreSQL (for production). Create the tables with Rakka::EventStore::Postgres.create_schema
  # c.event_store = Rakka::EventStore::Postgres.new(host: "localhost", dbname: "myapp", user: "app", password: "...")
end
```

Every other setting is optional.

| Setting | Default | Meaning |
|---|---|---|
| `shard_count` | number of cores | Number of shard Ractors. Sets parallelism, not the number of actors |
| `passivate_after` | 300 | Release an actor from memory after this many idle seconds |
| `max_actors_per_shard` | 10,000 | Actors one shard keeps in memory; beyond this, the least recently used are released |
| `throughput` | 5 | Messages one actor handles in a row before the shard moves on |
| `mailbox_capacity` | unlimited | Messages one actor can have queued |
| `snapshot_every` | 100 | Save a snapshot every this many events. `false` disables snapshots |
| `rebalance` | `true` | Move actors to idle shards when load is uneven (self-tuning) |

## Use it

```ruby
account = BankAccount.new("account-123")
account.deposit(1000)  # => [:ok, #<data MoneyDeposited amount=1000>]
account.withdraw(5000) # => [:rejected, :insufficient_funds]
account.balance        # => 1000
```

`BankAccount.new` is a lightweight handle with no Ractor or thread of its own; create as many as you like. The state lives inside a shard Ractor and is rebuilt from events when it is not in memory.

| Call | Result or error |
|---|---|
| `send_command_sync` | `[:ok, event]` (`[:ok, [e1, e2]]` for several), `[:rejected, reason]` or `[:noop]` |
| `send_command` | Does not wait for a reply (fire and forget) |
| `handle` or `apply_event` raised | `Rakka::ActorCrashed` |
| The mailbox is full | `Rakka::MailboxFull` |
| The shard is not running | `Rakka::ShardUnavailable` |

## Subscribe to events

```ruby
Rakka.subscribe(BankAccount::MoneyDeposited) do |event, metadata|
  # metadata: { stream_id: "BankAccount-account-123", actor_id: "account-123", version: 3 }
  puts "#{event.amount} deposited to #{metadata[:actor_id]}"
end

Rakka.subscribe_all { |event, metadata| ... } # every event
```

{: .warning }
Handlers are called at most once, and only in the process that wrote the event. If the process dies right after writing, the handler never sees that event. For read models that must not miss anything, see [the sample app](sample-app.html#read-models).
