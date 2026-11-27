---
title: Sample app
nav_order: 5
---

# Sample app (Auction House)
{: .no_toc }

[`examples/auction_house`](https://github.com/Ya-Suzuki/rakka/tree/main/examples/auction_house) is a Rails 8.1 app built around online auctions. Its user interface is in Japanese.

1. TOC
{:toc}

## Why auctions

- **Bids pile up on one listing**: "read the highest bid, accept if higher" must be correct without locks. With one actor per listing, bids queue in its mailbox and are decided one at a time
- **The history itself matters**: who bid how much and when is lost in a design that only keeps the current price. With event sourcing it is all kept, and any past state can be reproduced
- **Several read models**: the listing index and the bidder leaderboard are both built from the same events

## Run it

```bash
docker compose up -d          # at the repository root (PostgreSQL)
cd examples/auction_house
bundle install
bin/rails db:setup            # create, migrate and seed
bin/rails server
```

Open http://localhost:3000 and switch the name at the top right to list items and bid as different people.

## Concurrent bidding

```bash
bin/rails auction:bidding_war     # 20 bidders × 10 bids on one listing at once
```

```
bids: 200 (1670/s)
  accepted: 36
  rejected: 164 (below the minimum bid)

checks
  accepted bids = recorded bid events: OK
  every bid is at least 100 above the previous highest: OK
  current price = highest accepted bid (6300): OK
```

(The task prints these lines in Japanese.)

Each bidder reads the current price and bids above it, but other bids are processed in between. Because the actor decides one bid at a time, bids based on a stale price are correctly rejected. The app has no locks.

## Time travel

An auction's page lists all of its events. Click one to see the state as of that event. Past states are not stored anywhere: they are rebuilt by applying the events in order with `apply_event`.

## Read models

The listing index and the leaderboard come from separate tables (`auction_listings`, `bids`). [`Projections.apply`](https://github.com/Ya-Suzuki/rakka/blob/main/examples/auction_house/app/projections/projections.rb), subscribed to events, keeps the last projected version per stream in `stream_checkpoints`, updated in the same transaction as the read models.

| What happens | Result |
|---|---|
| The same event arrives twice | Its version is already projected, so it is ignored |
| An event never arrived (the process died before publishing) | When the next event arrives, the missing ones are read from the event store |
| Several processes publish events for one listing | The checkpoint row lock applies them in order |
| The read model changed, or a new one was added | `bin/rails projections:rebuild` rebuilds from every event |

Rakka delivers events at most once, but read models built this way do not miss any.

## Testing aggregates

`handle` and `apply_event` are pure functions, so you can test them as "past events + command → new events", without a database or actors.

```ruby
def decide(given, command)
  actor = Auction.behavior("test")
  state = given.reduce(actor.initial_state) { |s, event| actor.apply_event(event, s) }
  actor.handle(command, state)
end

test "a bid at or above the buyout price places the bid and closes the auction" do
  given = [Auction::Opened["Camera", "alice", 1000, 3000]]

  assert_equal [:persist, Auction::BidPlaced["bob", 3000], Auction::Closed["bob", 3000, "buyout"]],
               decide(given, Auction::PlaceBid["bob", 9999])
end
```
