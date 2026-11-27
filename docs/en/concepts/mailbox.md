---
title: Mailboxes and messaging
parent: How it works
nav_order: 2
---

# Mailboxes and messaging
{: .no_toc }

1. TOC
{:toc}

## One mailbox per actor

A shard first sorts incoming messages into the mailbox of the target actor. It then visits actors that have mail in turn, handling up to `throughput` messages (5 by default) for one actor before moving to the next, the same way Akka's dispatcher works.

With `throughput: 2`, sending six messages to `busy` and then one to `other` is processed in this order:

```
busy busy other busy busy busy busy
```

A backlog on one actor does not hold the others back for long: every other actor on the shard gets a turn every `throughput` messages. Messages for one actor are always processed in arrival order.

{: .note }
Actors switch only between messages. If `handle` blocks for a long time, every other actor on that shard waits too.

## Mailbox capacity

With `mailbox_capacity` set, an actor whose queue has reached that size accepts no more messages. Instead of using more and more memory when processing falls behind, senders are told the actor is overloaded.

| How it was sent | When the mailbox is full |
|---|---|
| `send_command_sync` | `Rakka::MailboxFull` |
| `send_command` | Dropped with a warning |

## Messaging between actors

Inside `handle`, create a handle for another actor and send it an asynchronous command.

```ruby
def deposit_later(amount) = send_command(Deposit[amount])

def handle(command, state)
  case command
  in Transfer(to:, amount:)
    Account.new(to).deposit_later(amount)
    [:persist, MoneyTransferred[to, amount]]
  end
end
```

- Messages are sent after the command's events are persisted. Attempts that raise, or that are retried after a conflict, send nothing
- Delivery is at most once. If the process dies right after persisting, the message is lost; use event subscribers for anything that must arrive
- `handle` cannot wait for a reply (`send_command_sync`, `state`): that would stall the shard, and deadlock if the other actor lives on the same shard
