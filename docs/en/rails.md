---
title: Using with Rails
nav_order: 4
---

# Using with Rails
{: .no_toc }

1. TOC
{:toc}

## Setup

```ruby
# Gemfile
gem "rakka", github: "Ya-Suzuki/rakka", glob: "rakka-core/*.gemspec"
gem "rakka-rails", github: "Ya-Suzuki/rakka", glob: "rakka-rails/*.gemspec"
```

```bash
bin/rails generate rakka:install          # migrations (events / snapshots) and config/initializers/rakka.rb
bin/rails db:migrate
bin/rails generate rakka:aggregate Order  # app/aggregates/order.rb
```

The connection comes from `database.yml`. To add only the tables to an existing app, run `bin/rails rakka:create_schema` (it creates missing tables only); `bin/rails rakka:info` shows the current settings.

## Configuration

```ruby
# config/initializers/rakka.rb
Rails.application.config.rakka = {
  shard_count: 4,
  snapshot_every: 100,
  database_config_name: :primary, # which database.yml entry to use
  auto_configure: true            # set to false to call Rakka.configure yourself
}

# Project events into read models
Rakka.subscribe_all { |event, metadata| Projections.apply(event, metadata) }
```

`shard_count`, `passivate_after`, `max_actors_per_shard`, `throughput`, `mailbox_capacity`, `snapshot_every` and `rebalance` in `config.rakka` are passed to Rakka. Their meaning is in the table in [Get started](getting-started.html#configure).

## What rakka-rails does for you

| What | How |
|---|---|
| Settings | Applied after `config/initializers` has run (`after_initialize`) |
| Executor | Event handlers run inside the Rails executor, so Rails returns database connections and coordinates with code reloading |
| Code reloading | In development, the actor system is stopped before a reload. The next command starts it again and actors recover from their events |

Without the reload handling, shards keep actors of the old classes, commands of the new classes reach them, and the first command after every reload fails.

## In production

- Each process has its own shard Ractors. In Puma's cluster mode every worker gets an independent actor system (it starts on the first command, so after the fork)
- Concurrent writes from different workers are detected by [optimistic locking](concepts/persistence.html#optimistic-locking) and retried, so streams stay consistent
- Each process opens `shard_count + 1` PostgreSQL connections, on top of Active Record's pool

## Things to watch

{: .warning }
`handle` and `apply_event` run inside a shard Ractor. Do not touch Active Record or global state there; use only the arguments.

- **Put aggregates in `app/aggregates/`**, and define their commands and events with `Data.define` inside the class
- **Mind the query cache when waiting for read models**: inside requests and tests, the same SQL returns a cached result and appears never to change. Check inside `ActiveRecord::Base.uncached { ... }`
- **Tests do not roll events back**: Rakka writes events on its own connections, so transactional tests do not remove them. Empty the tables per test, as the sample app's `test/test_helper.rb` does

For a working app, see the [sample app](sample-app.html).
