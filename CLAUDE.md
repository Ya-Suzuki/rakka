# CLAUDE.md

Claude Code (claude.ai/code) 向けのプロジェクトガイダンス。

## プロジェクト概要

**Rakka** (Ractor + Akka) - Ruby 4.0のRactorを使ったアクターベースのイベントソーシングライブラリ。

## パッケージ構成

```
rakka/
├── rakka-core/     # コアライブラリ (gem "rakka")
└── rakka-rails/    # Rails統合 (gem "rakka-rails")
```

## コマンド

```bash
# rakka-core開発
cd rakka-core
bundle install
bundle exec rspec

# PostgreSQLを使ったテスト
docker compose up -d
ruby examples/postgres_demo.rb
```

## アーキテクチャ

### コアコンポーネント (rakka-core/lib/rakka/)

| ファイル | 役割 |
|---------|------|
| `persistent_actor.rb` | Ractor内で動作するアクター。コマンド処理、イベント永続化、状態管理 |
| `event_store/memory.rb` | テスト用のインメモリEventStore |
| `event_store/postgres.rb` | 本番用PostgreSQL EventStore（コネクションプール付き） |
| `shard_coordinator.rb` | stream_idからシャードへの負荷ベースアサイン |
| `actor_registry.rb` | Actorのライフサイクル管理、Passivation（アイドル時自動解放） |
| `supervisor.rb` | Ractor#monitorを使ったクラッシュ検知と自動リスタート |
| `event_bus.rb` | イベントハンドラの登録と呼び出し |
| `event_publisher.rb` | Ractor→MainThreadへのイベント橋渡し（Port経由） |

### メッセージフロー

```
PersistentActor (Ractor)
    ↓ [:command, cmd, reply_port]
handle(cmd, state) → [:persist, event]
    ↓ [:append, stream_id, event, reply_port]
EventStore (Ractor Worker)
    ↓ PostgreSQL/Memory
    ↓ apply_event(event, state) → 新しい状態
    ↓ [:publish, event, metadata]
EventPublisher (Port → Thread)
    ↓
EventBus (Main Thread) → subscribers
```

### Ractor通信パターン

```ruby
# Ractor::Port を使った同期通信
reply_port = Ractor::Port.new
ractor.send([:command, cmd, reply_port])
result = reply_port.receive  # ブロック

# Portなしの非同期通信
ractor.send([:command, cmd, nil])
```

## Ractor制約

- **Shareable Objects のみ通信可能**: 数値、Symbol、frozen String、`Data.define`
- **可変オブジェクト共有不可**: 競合状態を設計レベルで防止
- **Ractor Safe Gems**: `pg` ○、`sqlite3` ×、`mysql2` ×

## コーディングガイドライン

### コマンド・イベント定義

```ruby
# Data.define を使う（Ractor間で共有可能）
Deposit = Data.define(:amount)
MoneyDeposited = Data.define(:amount)

# 使用例
event = MoneyDeposited[100]  # または MoneyDeposited.new(amount: 100)
```

### handle() の戻り値

```ruby
def handle(command, state)
  case command
  in Deposit(amount:)
    [:persist, MoneyDeposited[amount]]  # イベントを永続化
  in Withdraw(amount:) if state[:balance] < amount
    [:reject, :insufficient_funds]       # コマンド拒否
  else
    [:noop]                              # 何もしない
  end
end
```

### apply_event() は純粋関数

```ruby
def apply_event(event, state)
  case event
  in MoneyDeposited(amount:)
    state.merge(balance: state[:balance] + amount)
  end
  # 必ず新しいstateを返す（既存stateを変更しない）
end
```

## テスト

```bash
# 全テスト
bundle exec rspec

# 特定ファイル
bundle exec rspec spec/rakka/persistent_actor_spec.rb

# 特定行
bundle exec rspec spec/rakka/persistent_actor_spec.rb:42
```

## 注意点

- Ruby 4.0+ が必要（Ractor::Port API）
- PostgreSQL使用時は `pg` gem のみサポート（Ractor safe）
- Actorの状態はイベントから再構築されるため、イベントは不変であること
