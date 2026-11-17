# frozen_string_literal: true

# Rakka configuration
Rails.application.config.rakka = {
  # Number of shard Ractors per process (default: number of CPU cores).
  # Actors are multiplexed onto these, so this sets parallelism, not actor count.
  # Each shard holds one database connection (+1 for the main thread).
  # shard_count: 4,

  # Release an actor's in-memory state after this many idle seconds (default: 300)
  # passivate_after: 300,

  # Max actors kept in memory per shard, evicted LRU (default: 10_000)
  # max_actors_per_shard: 10_000,

  # Messages one actor handles in a row before the shard moves on to the
  # next actor with mail (default: 5)
  # throughput: 5,

  # Max messages queued per actor; beyond this, senders get Rakka::MailboxFull
  # (default: unlimited)
  # mailbox_capacity: 1_000,

  # Save a state snapshot every N events so recovery replays fewer events
  # (default: 100, false to disable)
  # snapshot_every: 100,

  # Move backlogged actors to shards with spare capacity. Self-tuning; set to
  # false to keep every actor on the shard its id hashes to (default: true)
  # rebalance: true,

  # Database configuration to use (from database.yml)
  database_config_name: :primary,

  # Set to false to configure manually
  auto_configure: true
}

# Event handlers
# Rakka.subscribe(YourAggregate::SomeEvent) do |event, metadata|
#   # Update read models
#   YourReadModel.create_from_event(event)
#
#   # Broadcast via ActionCable
#   ActionCable.server.broadcast("channel", event.to_h)
#
#   # Enqueue background job
#   SomeJob.perform_later(event.to_h)
# end

# 書き込まれたイベントを読みモデルに反映する（Projections.apply は再送・欠落に強い）
Rakka.subscribe_all { |event, metadata| Projections.apply(event, metadata) }
