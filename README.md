# Rakka

**Ractor-based Actor Event Sourcing for Ruby**

RubyのRactor（Ruby 4.0+）を使った、アクターベースのイベントソーシングライブラリ。
Akkaにインスパイアされた設計で、真の並列処理とメモリ隔離を実現。

名前の由来: **Ra**ctor + **Akka** = **Rakka**

## 特徴

- **Ractor Native**: GVLを回避した真の並列処理
- **Event Sourcing**: イベントを永続化し、状態を再構築可能
- **Actor Model**: メッセージパッシングによる安全な並行処理
- **Passivation**: アイドル時にActorを自動解放してメモリ節約
- **Supervisor**: クラッシュ検知と自動リスタート
- **EventBus**: 非同期イベントハンドリング

## パッケージ構成

```
rakka/
├── rakka-core/     # コアライブラリ (gem "rakka")
└── rakka-rails/    # Rails統合 (gem "rakka-rails")
```

## インストール

```ruby
# Gemfile
gem "rakka", path: "path/to/rakka/rakka-core"

# Rails統合が必要な場合
gem "rakka-rails", path: "path/to/rakka/rakka-rails"
```

## 基本的な使い方

### 1. Aggregateの定義

```ruby
class BankAccount < Rakka::PersistentActor
  # Commands
  Deposit = Data.define(:amount)
  Withdraw = Data.define(:amount)

  # Events
  MoneyDeposited = Data.define(:amount)
  MoneyWithdrawn = Data.define(:amount)

  def initial_state
    { balance: 0 }
  end

  def deposit(amount)
    send_command_sync(Deposit[amount])
  end

  def withdraw(amount)
    send_command_sync(Withdraw[amount])
  end

  def balance
    state[:balance]
  end

  def handle(command, state)
    case command
    in Deposit(amount:)
      [:persist, MoneyDeposited[amount]]

    in Withdraw(amount:)
      if state[:balance] >= amount
        [:persist, MoneyWithdrawn[amount]]
      else
        [:reject, :insufficient_funds]
      end
    end
  end

  def apply_event(event, state)
    case event
    in MoneyDeposited(amount:)
      state.merge(balance: state[:balance] + amount)
    in MoneyWithdrawn(amount:)
      state.merge(balance: state[:balance] - amount)
    end
  end
end
```

### 2. 設定とEventStore

```ruby
Rakka.configure do |c|
  # メモリ（テスト用）
  c.event_store = Rakka::EventStore::Memory.new

  # PostgreSQL（本番用）
  c.event_store = Rakka::EventStore::Postgres.new(
    pool_size: 5,
    host: "localhost",
    dbname: "myapp",
    user: "postgres",
    password: "password"
  )
end
```

### 3. 使用

```ruby
account = BankAccount.new("account-123")
account.deposit(1000)
account.withdraw(300)
puts account.balance  # => 700

# 再起動後も状態が復元される
recovered = BankAccount.new("account-123")
puts recovered.balance  # => 700
```

### 4. イベントハンドラ

```ruby
Rakka.subscribe(BankAccount::MoneyDeposited) do |event, metadata|
  puts "Deposited: #{event.amount}"

  # Read Model更新
  AccountSummary.update_balance(metadata[:actor_id], event.amount)

  # ActionCableでブロードキャスト（Rails）
  ActionCable.server.broadcast("accounts", { type: "deposit", amount: event.amount })
end
```

## コンポーネント

### PersistentActor

Ractor内で動作するアクター。コマンドを受け取り、イベントを永続化し、状態を管理。

```ruby
class MyActor < Rakka::PersistentActor
  def initial_state       # 初期状態
  def handle(cmd, state)  # コマンド処理 → [:persist, event] | [:reject, reason] | [:noop]
  def apply_event(e, s)   # イベント適用 → 新しい状態
end
```

### EventStore

イベントの永続化を担当。

| Store | 用途 | 特徴 |
|-------|------|------|
| `Memory` | テスト | Ractor内のHashに保存 |
| `Postgres` | 本番 | コネクションプール + ShardCoordinator |

### ActorRegistry

Actorのライフサイクル管理。Passivation（アイドル時解放）をサポート。

```ruby
registry = Rakka::ActorRegistry.new(passivate_after: 30)  # 30秒でpassivate
actor = registry.get_or_create(BankAccount, "account-123")
```

### Supervisor

Actorのクラッシュ検知と自動リスタート。

```ruby
supervisor = Rakka::Supervisor.new(max_restarts: 3, within: 60).start
actor = supervisor.supervise(MyActor, "id-1")
# クラッシュ時は自動リスタート（3回/60秒まで）
```

### EventBus

イベント発生時にハンドラを呼び出す。非同期コマンドでも動作。

```ruby
Rakka.subscribe(SomeEvent) { |event, metadata| ... }
Rakka.subscribe_all { |event, metadata| ... }  # 全イベント
```

## 開発

```bash
# 依存関係インストール
cd rakka-core && bundle install

# テスト実行
bundle exec rspec

# PostgreSQL起動（Docker）
docker compose up -d

# PostgreSQLデモ
ruby examples/postgres_demo.rb
```

## アーキテクチャ

```
┌─────────────────┐     ┌──────────────────────┐
│  PersistentActor │────▶│  EventStore (Ractor) │
│    (Ractor)      │     │  ┌─────────────────┐ │
│                  │     │  │ Worker Pool     │ │
│  - handle()      │     │  │ (PostgreSQL)    │ │
│  - apply_event() │     │  └─────────────────┘ │
└────────┬─────────┘     └──────────────────────┘
         │
         ▼
┌─────────────────┐     ┌──────────────────────┐
│ EventPublisher  │────▶│  EventBus            │
│   (Port)        │     │  (Main Thread)       │
│                 │     │  - subscribe()       │
│                 │     │  - Read Model更新    │
│                 │     │  - ActionCable       │
└─────────────────┘     └──────────────────────┘
```

## Ractor制約

- Ractor間で渡せるのは **shareable objects** のみ
  - 数値、Symbol、frozen String、`Data.define`
- 可変オブジェクトの共有不可 → 競合状態を設計レベルで防止
- `pg` gemはRactor safe、`sqlite3`/`mysql2`はRactor unsafe

## ライセンス

MIT
