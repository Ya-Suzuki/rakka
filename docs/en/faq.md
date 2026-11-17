---
title: FAQ
nav_order: 6
---

# FAQ
{: .no_toc }

1. TOC
{:toc}

## Aren't Erlang and Akka "one actor, one process"?

It depends on what "process" means.

- **Erlang**: logically, yes. But that process is a lightweight process created by the BEAM VM (a few KB), neither an OS process nor a thread. A scheduler thread per core switches between hundreds of thousands to millions of them
- **Akka**: there is no execution unit per actor. An actor is an object holding state, a mailbox and a handler, and it borrows a thread from a pool only while handling messages

Both are "many actors on few OS threads". The difference is whether an actor has its own stack. Rakka follows Akka (no stack per actor).

## Is it still one actor per aggregate?

Yes. Akka Persistence and the Erlang/Elixir CQRS libraries (such as Commanded) use one actor per aggregate, and so does Rakka. What is not one to one is actors to execution units (OS threads or Ractors). See [Actors and Ractors](concepts/actors-and-ractors.html).

## Are actors supervised individually?

Yes. Akka also supervises, restarts and watches each actor. Erlang processes really terminate at the VM level; Akka reaches the same semantics by catching the exception, dropping the state and recreating the actor. Rakka handles actors the Akka way and shards the Erlang way (`Ractor#monitor`). See [Failure handling](concepts/failures.html).

## If actors are not Ractors, why use Ractors at all?

They provide parallelism and enforced isolation.

- Shards are not bound by the GVL, so one process uses several cores
- Only shareable objects cross Ractors, so isolated state and immutable events are guaranteed by the language
- When a shard dies the others keep running, and it can be detected and restarted

The gains shrink when:

- **Most of the time is spent waiting on the database**: there is little CPU work to parallelise
- **You run Puma with several processes**: the cores are already used by processes
- **Garbage collection is heavy**: GC pauses every Ractor, so allocation-heavy work stops scaling

Ractors pay off when replaying events or `handle` is CPU-bound and you want one process to use every core.

## Is it safe to write one aggregate from several Rails processes?

Yes. Appends use optimistic locking; if another process wrote first, the state is reloaded and the command decided again. An actor in memory acts as a cached state with in-process ordering, not as a single-writer guarantee.

## Are event handlers always called?

No, delivery is at most once. If the process dies right after writing an event, the handler never sees it. For read models that must not miss anything, follow the [sample app's read models](sample-app.html#read-models): ignore duplicates by version and fill gaps from the event store.

## What should I watch when changing `apply_event`?

A snapshot is state built with the `apply_event` of its time. If a change alters the result, bump `snapshot_schema`; old snapshots are then ignored and the state is rebuilt from events. Events themselves are immutable, so never rewrite them.
