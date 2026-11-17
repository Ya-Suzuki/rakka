---
title: How it works
nav_order: 3
has_children: true
permalink: /en/concepts/
---

# How it works

How Rakka works inside. [Get started](../getting-started.html) is enough to use it; these pages help when you reason about performance or failures.

```
 BankAccount.new(id)          handle (no Ractor)
        │ command
        ▼
┌──────────────────────────────────────────────┐
│ ActorSystem   routing (home + moved actors)  │
└───────┬──────────────────────┬───────────────┘
        ▼                      ▼
┌────────────────┐     ┌────────────────┐
│ Shard (Ractor) │     │ Shard (Ractor) │  … one per core (watched by Supervisor)
│ per-actor      │     │                │
│ mailboxes and  │     │                │
│ state          │     │                │
│ Journal        │     │ Journal        │
└───┬────────┬───┘     └───┬────────┬───┘
    │        │ append(expected_version)
    │        ▼             │        ▼
    │   ┌──────────────────────────────┐
    │   │ EventStore (PostgreSQL etc.) │
    │   └──────────────────────────────┘
    ▼ publish              ▼
┌─────────────────┐     ┌──────────────────────┐
│ EventPublisher  │────▶│  EventBus            │
│   (Port)        │     │  (main thread)       │
└─────────────────┘     └──────────────────────┘
```
