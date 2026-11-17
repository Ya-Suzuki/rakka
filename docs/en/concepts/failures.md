---
title: Failure handling
parent: How it works
nav_order: 5
---

# Failure handling

Failures are handled at two levels. Both recover the same way: drop the state and rebuild it from events (let it crash). Events are the source of truth, so dropping in-memory state loses nothing.

| Level | Trigger | What happens |
|---|---|---|
| Actor | `handle` or `apply_event` raises a `StandardError` or `ScriptError` | Only that actor's state is dropped and the caller gets `Rakka::ActorCrashed`. Other actors on the shard are unaffected |
| Shard | A shard Ractor dies from any other exception | The Supervisor restarts it (by default up to three times in 60 seconds). Callers waiting on it get `Rakka::ShardUnavailable`. Its actors recover on their next command |

This mirrors Akka. In Erlang a process really terminates at the VM level; Akka gets the same semantics in a library by catching the exception, dropping the state and recreating the actor. Rakka's actor level does the same.

{: .note }
An infinite loop inside `handle` cannot be stopped per actor; only the whole shard can be stopped. Akka has the same limitation.
