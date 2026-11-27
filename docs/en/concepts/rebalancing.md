---
title: Rebalancing
parent: How it works
nav_order: 3
---

# Rebalancing
{: .no_toc }

1. TOC
{:toc}

## Why it is needed

Hashing spreads actors evenly when there are many of them. But when busy actors happen to land on the same shard, that shard backs up while other cores sit idle. Rakka moves waiting actors, mailbox and all, to idle shards.

Sixteen CPU-bound actors all hashed to one shard, on four cores:

| | Time | Messages per shard |
|---|---|---|
| Without rebalancing | 4.8 s | 800 / 0 / 0 / 0 |
| With rebalancing | 1.6 s | 215 / 195 / 205 / 185 |

## When and what to move

There is nothing to tune (`rebalance: false` only turns it off). Each shard measures how long one message takes and how long recovering one actor takes, and an actor is moved only when all of these hold:

1. The gap between the busiest and the idlest shard is larger than the cost of moving (including recovery)
2. The destination will have spare capacity by the time the move is done (moving when every shard is busy only adds overhead)
3. The actor finishes sooner after moving than by waiting where it is (when load is concentrated on one actor, moving only moves the imbalance, so it stays)

Backlogs are compared as estimated time to drain (queued messages × time per message), not as counts. The check interval adapts too: 10 ms while there is an imbalance, up to 0.5 s when there is none.

## A handoff that keeps order

Message order for each actor is preserved during a move.

1. Tell the destination a handoff is coming. It holds messages for that actor until the handoff arrives
2. Switch the route. New messages go to the destination and are held there
3. The source releases the actor and hands its queued messages to the destination
4. The destination queues the handed-over messages first, then the held ones, and resumes

State itself is not moved; the destination rebuilds it from the snapshot and events. Even if two shards ever processed the same actor, [optimistic locking](persistence.html#optimistic-locking) keeps the stream consistent.

```ruby
system.migrate("BankAccount-123", 2)   # you can also move an actor by hand
system.shard_index("BankAccount-123")  # => 2
```

{: .note }
Rebalancing happens between shards within a process. Actors are never moved across processes.
