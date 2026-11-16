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

# PostgreSQLを使ったテスト（接続できない場合、postgres_specはスキップされる）
docker compose up -d
bundle exec rspec spec/rakka/event_store/postgres_spec.rb
ruby examples/postgres_demo.rb
```

## アーキテクチャ

**アクター ≠ Ractor**。Ractorはシャード数（≒コア数）だけ作り、アクターはシャードRactor内のHashエントリ（behavior + state + version）として同居する（Akkaのディスパッチャ方式）。アクター数を増やしてもRactorは増えない。

### コアコンポーネント (rakka-core/lib/rakka/)

| ファイル | 役割 |
|---------|------|
| `persistent_actor.rb` | 集約の定義（`initial_state` / `handle` / `apply_event`）と、コマンドを転送するだけの軽いハンドル。Ractorは持たない |
| `actor_system.rb` | シャードRactorの起動、`crc32(stream_id) % shard_count` でのルーティング、返信待ちの管理 |
| `shard.rb` | シャードRactor本体。アクターごとのメールボックスとスケジューリング、アクターの復元・コマンド処理・Passivation（アイドル/LRU）・アクター単位のクラッシュ処理 |
| `supervisor.rb` | Ractor#monitorでシャードRactorの異常終了を検知して再起動 |
| `event_store/base.rb` | EventStore共通API、`Serialization` |
| `event_store/memory.rb` | テスト用のインメモリEventStore |
| `event_store/postgres.rb` | 本番用PostgreSQL EventStore（Journalごとに1コネクション） |
| `event_bus.rb` | イベントハンドラの登録と呼び出し |
| `event_publisher.rb` | Ractor→MainThreadへのイベント橋渡し（Port経由） |

### メッセージフロー

```
BankAccount.new(id).deposit(...)          # ハンドル（Main Ractor）
    ↓ ActorSystem#ask → [:command, actor_class, id, stream_id, cmd, reply_port]
Shard (Ractor)                            # stream_idごとに固定のシャード
    ↓ dispatch: 宛先アクターのメールボックスに入れる
    ↓ メッセージを持つアクターを順番に throughput 件ずつ処理
    ↓ activate: メモリに無ければ journal.read でイベントを再生
    ↓ handle(cmd, state) → [:persist, event]
    ↓ journal.append(stream_id, expected_version, events)   # 楽観ロック
    ↓ apply_event(event, state) → 新しい状態
    ↓ [:publish, event, metadata]
EventPublisher (Port → Thread)
    ↓
EventBus (Main Thread) → subscribers
```

### メールボックスとスケジューリング

- メールボックスはアクターごと。`@mailboxes`（stream_id => 未処理メッセージ）は空になったら消すので、Hashの挿入順がそのままランキューになる
- シャードは先頭のアクターを `throughput` 件（デフォルト5）処理し、残りがあれば列の最後に回す。1つのアクターにコマンドが溜まっても他のアクターを待たせ続けない
- `Ractor.receive` にはノンブロッキング版が無いので、自分宛てに目印（`DRAINED`）を送り、それを受け取るまで読むことで「今届いている分」だけを振り分ける
- `[:command]` / `[:get_state]` / `[:passivate]` はメールボックス経由（アクターごとに到着順）。`[:tick]` / `[:stats]` / `[:stop]` はシャード宛てで即時処理

### EventStoreとJournal

- EventStoreは `connector`（shareable）を公開し、各シャードRactorが `connector.connect` で自分専用のJournalを持つ
- `journal.append(stream_id, expected_version, events)` はバージョンが食い違うと `ConcurrencyError`
- version = ストリーム内のイベント数。PostgreSQLでは `UNIQUE(stream_id, position)` が競合を検出する
- 競合時、シャードはキャッシュした状態を捨て、読み直してコマンドを判定し直す（複数プロセスから書いても整合する）

### 障害処理（2層）

| 層 | きっかけ | 動作 |
|----|---------|------|
| アクター | `handle` / `apply_event` が StandardError / ScriptError | そのアクターの状態だけ破棄し、呼び出し側に `ActorCrashed`。次のコマンドでイベントから復元 |
| シャード | それ以外の例外でRactorが異常終了 | Supervisorが再起動。待っていた呼び出しは `ShardUnavailable`。載っていたアクターは順次復元 |

### Ractor通信パターン

```ruby
# Ractor::Port を使った同期通信
reply_port = Ractor::Port.new
ractor.send([:command, actor_class, id, stream_id, cmd, reply_port])
result = reply_port.receive  # ブロック

# Portなしの非同期通信
ractor.send([:command, actor_class, id, stream_id, cmd, nil])
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
    [:persist, MoneyDeposited[amount]]  # イベントを永続化（複数なら [:persist, e1, e2]）
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

- `handle` / `apply_event` / `initial_state` はシャードRactor内で実行される。メインRactorの状態（グローバル変数、非shareableな定数、`Rakka.system`）には触れないこと
- `handle` の中でブロックすると、同じシャードの他のアクターも待たされる（切り替えはメッセージの合間だけで、処理中のメッセージは中断できない）
- ActorSystemは初回コマンドで起動する（fork後の各プロセスが自分のシャードを持つ）

- Ruby 4.0+ が必要（Ractor::Port API）
- PostgreSQL使用時は `pg` gem のみサポート（Ractor safe）
- Actorの状態はイベントから再構築されるため、イベントは不変であること
