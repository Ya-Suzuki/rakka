---
title: Persistence and recovery
parent: How it works
nav_order: 4
---

# Persistence and recovery
{: .no_toc }

1. TOC
{:toc}

## Event stores and journals

The event store is where events are kept. Each shard Ractor gets its own journal from the store (for PostgreSQL, one connection) and reads and writes through it.

| Store | Use | Notes |
|---|---|---|
| `Memory` | Tests | Keeps events in a Hash inside a Ractor |
| `Postgres` | Production | One connection per shard (`shard_count + 1` per process) |

## Optimistic locking

Every append carries an expectation: "this stream is at version N". In PostgreSQL, `UNIQUE(stream_id, position)` detects a mismatch.

On a mismatch (another process wrote first), the shard drops the in-memory state, rebuilds it from the latest events and decides the command again (up to three times). So several processes, such as Puma workers, can write to the same aggregate safely.

{: .note }
An actor in memory is not a single-writer guarantee; it is a cached state plus in-process ordering. Correctness comes from optimistic locking.

## Snapshots

As events pile up, replaying all of them on every recovery gets slow. Rakka saves the state every `snapshot_every` events (100 by default) and replays only the events after the latest snapshot. Recovering a 10,000-event stream from PostgreSQL went from about 28 ms to 0.3 ms.

```ruby
class Ledger < Rakka::PersistentActor
  snapshot_every 500    # a different interval for this class (nil disables)
  snapshot_schema 2     # bump when the state shape or apply_event changes
end
```

- Only the latest snapshot per stream is kept. Events are never deleted
- Snapshots with a different `snapshot_schema` are ignored and the state is rebuilt from events
- Treat snapshots as a disposable cache: a failed save only warns, and an unreadable one counts as missing
- PostgreSQL stores them in `rakka_snapshots` with Marshal, so state must be marshalable

{: .warning }
Bump `snapshot_schema` whenever a change alters what `apply_event` produces. Otherwise actors recover from state built with the old meaning.

## Passivation

An actor is released from memory after `passivate_after` idle seconds, or when its shard holds more than `max_actors_per_shard`. The next command rebuilds it from the snapshot and events.

```ruby
account.stop # release it now
```
