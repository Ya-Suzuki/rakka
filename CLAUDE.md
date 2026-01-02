# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Rakka (Ractor + Akka) - RubyのRactorを使ったアクターベースのイベントソーシングライブラリ。

## Commands

```bash
# Install dependencies
bundle install

# Run all tests
bundle exec rspec

# Run a single test file
bundle exec rspec spec/path/to_spec.rb

# Run a specific test by line number
bundle exec rspec spec/path/to_spec.rb:42
```

## Architecture

The library uses Ruby Ractors to provide true parallelism with memory isolation:

- **Actor** (`lib/rakka/actor.rb`): Spawns isolated Ractors that receive commands, process domain logic, emit events to the EventStore, and update internal state. Actors communicate via message passing using `Ractor.send` and `Ractor.receive`.

- **EventStore** (`lib/rakka/event_store.rb`): A dedicated Ractor that receives and persists events from actors. Runs in its own isolated loop collecting domain events.

### Message Flow

1. External code sends commands to an Actor via `actor.send(command)`
2. Actor processes the command and validates business rules
3. If valid, Actor creates an event and sends it to EventStore
4. Actor updates its own internal state
5. EventStore persists the event

### Key Constraints

- All messages between Ractors must be frozen or shareable
- Each Ractor has isolated state - no shared mutable memory
- Communication is strictly message-based (no shared variables)
