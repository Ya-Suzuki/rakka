---
title: Development
nav_order: 7
---

# Development
{: .no_toc }

1. TOC
{:toc}

## Layout

```
rakka/
├── rakka-core/               # core library (gem "rakka")
├── rakka-rails/              # Rails integration (gem "rakka-rails")
├── examples/auction_house/   # sample Rails app
└── docs/                     # this site (GitHub Pages)
```

## Tests

Start each from the repository root. Without PostgreSQL, everything except the PostgreSQL specs still runs.

```bash
docker compose up -d   # PostgreSQL

# rakka-core
cd rakka-core && bundle install && bundle exec rspec

# rakka-rails (boots a minimal Rails app to test the Railtie and generators)
cd rakka-rails && bundle install && bundle exec rspec

# sample app
cd examples/auction_house && bundle install && bin/rails db:setup && bin/rails test
```

## Demo scripts

Run them with `cd rakka-core && ruby examples/<file>`. Only `postgres_demo.rb` needs PostgreSQL. Their output is in Japanese.

| File | Shows |
|---|---|
| `bank_account.rb` | A basic aggregate (deposit, withdraw, rejecting overdrafts, recovery) |
| `async_demo.rb` | Asynchronous commands and event handlers |
| `event_handler_demo.rb` | Handlers per event type and for every event |
| `passivation_demo.rb` | Releasing idle actors and recovering them from events |
| `supervisor_demo.rb` | An actor crash, and a shard Ractor restart |
| `transfer_demo.rb` | Messaging between actors (transfers between accounts) |
| `many_actors_demo.rb` | Memory and speed with many actors on few Ractors (pass the actor count) |
| `postgres_demo.rb` | The PostgreSQL event store, recovery and optimistic locking |

## Editing this site

Pages are Markdown files under `docs/`; English pages live under `docs/en/` at the same paths as the Japanese ones. Use "Edit this page on GitHub" at the bottom of any page. GitHub Pages rebuilds the site when `main` changes.

New pages start with front matter:

```markdown
---
title: Page title
nav_order: 8
parent: How it works   # to place it under "How it works"
---
```
