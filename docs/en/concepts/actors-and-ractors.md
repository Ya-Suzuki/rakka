---
title: Actors and Ractors
parent: How it works
nav_order: 1
---

# Actors and Ractors
{: .no_toc }

1. TOC
{:toc}

## Three layers

Rakka keeps three things apart.

| Layer | Meaning | In Rakka |
|---|---|---|
| Aggregate | A unit of the domain (account 123, auction 456) | A stream of events identified by `stream_id` |
| Actor | A logical unit that owns state and handles one message at a time | An entry inside a shard Ractor (behavior + state + version) |
| Execution unit | What actually runs code on a CPU | A shard Ractor (one per core) |

**Aggregate to actor is one to one.** Each account has its own state, its own serial processing, and crashes and recovers on its own. **Actor to execution unit is many to few**: many actors share a few shard Ractors.

## Why not one Ractor per actor?

A Ractor is a heavy execution unit with its own stack that runs in parallel. One Ractor per aggregate runs out of memory once aggregates reach thousands or tens of thousands.

Erlang and Akka handle hundreds of thousands of actors precisely because they do not map actors one to one onto OS threads.

| | What an actor is | Size | What runs it |
|---|---|---|---|
| Erlang | A lightweight BEAM process (own heap and stack) | a few KB | Scheduler threads (one per core) |
| Akka | An object plus a mailbox (no stack) | a few hundred bytes | A dispatcher's thread pool |
| Rakka | An entry inside a shard | about 1 KB | Shard Ractors (one per core) |

Ractors play the role of Erlang's schedulers or Akka's dispatcher. Fifty thousand actors on four shards used six Ractors in total (four shards, the main Ractor and the store).

## What Ractors still give you

Even without one Ractor per actor, Ractors do real work.

- **Parallel CPU**: shards are not bound by the GVL, so `handle`, `apply_event`, event replay during recovery and JSON conversion use several cores in one process
- **Enforced isolation**: only shareable objects cross Ractors, so "nobody touches an actor's state from outside" and "commands and events are immutable" are guaranteed by the language, not by convention
- **Failure boundaries**: when a shard dies, the others keep running, and `Ractor#monitor` detects it so it can be restarted

If most of the time is spent waiting on the database, the parallel CPU gains shrink. See the [FAQ](../faq.html).

## Routing

An actor's home shard is `crc32(stream_id) % shard_count`. Messages for one aggregate always reach the same shard, so they are processed in order without locks. When load is uneven, [rebalancing](rebalancing.html) may move an actor away from home.
