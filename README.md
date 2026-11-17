# Rakka

**Ractor-based Actor Event Sourcing for Ruby**

RubyのRactor（Ruby 4.0+）を使った、アクターベースのイベントソーシングライブラリ。
Akkaにインスパイアされた設計で、少数のRactor上に多数の軽量アクターを載せる。

名前の由来: **Ra**ctor + **Akka** = **Rakka**

## 特徴

- **Ractor Native**: GVLを回避した真の並列処理
- **軽量アクター**: アクターはRactorではなくシャードRactor内のエントリ。数万アクターでもRactorはコア数程度
- **アクター単位のメールボックス**: 公平なスケジューリング、容量の上限、アクター間メッセージング
- **リバランス**: 負荷が偏ると、溜まっているアクターを空いているシャードへ移す
- **Event Sourcing**: イベントを永続化し、状態を再構築可能
- **Actor Model**: メッセージパッシングによる安全な並行処理
- **楽観ロック**: 複数プロセスから同じ集約に書いても整合する
- **スナップショット**: 一定イベントごとに状態を保存し、復元を速くする
- **Passivation**: アイドル時・上限超過時にActorを自動解放してメモリ節約
- **Let it crash**: アクターの例外は状態を捨てて復元、シャードRactorの異常終了は自動リスタート
- **EventBus**: 非同期イベントハンドリング

## パッケージ構成

```
rakka/
├── rakka-core/               # コアライブラリ (gem "rakka")
├── rakka-rails/              # Rails統合 (gem "rakka-rails")
└── examples/auction_house/   # Railsのサンプルアプリ
```

## サンプルアプリ

[`examples/auction_house`](examples/auction_house) は、ネットオークションを題材にした Rails アプリです。1出品 = 1アクターでの同時入札、イベント履歴からのタイムトラベル表示、作り直せる読みモデルを、画面とコマンドで確かめられます。

## 必要環境

| | |
|---|---|
| Ruby | 4.0 以上（`Ractor::Port` を使う） |
| データベース | PostgreSQL（`pg` gem）。Ractorから使えないドライバ（`sqlite3`、`mysql2`）には対応しない |
| Rails（rakka-rails） | 7.0 以上。サンプルアプリは 8.1 で確認 |

テストやデモではメモリ上のEventStoreを使えるので、PostgreSQLは無くても動く。

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
    host: "localhost",
    dbname: "myapp",
    user: "postgres",
    password: "password"
  )

  c.shard_count = 4                # シャードRactor数（デフォルト: コア数）
  c.passivate_after = 300          # アイドル何秒でメモリから解放するか
  c.max_actors_per_shard = 10_000  # 1シャードがメモリに保持する上限（LRU）
  c.throughput = 5                 # 1アクターを続けて処理するメッセージ数
  c.mailbox_capacity = 1_000       # 1アクターに溜められるメッセージ数（デフォルト: 無制限）
  c.snapshot_every = 100           # 何イベントごとにスナップショットを保存するか。false で無効
  c.rebalance = true               # 負荷が偏ったらアクターを空いているシャードへ移す（調整は自動）
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
  # metadata: { stream_id: "BankAccount-account-123", actor_id: "account-123", version: 3 }
  puts "#{metadata[:actor_id]} に #{event.amount} 入金"
end
```

ハンドラへの配送は at-most-once で、同じプロセスの中だけで行われる（イベントを書いた直後にプロセスが落ちると、そのイベントはハンドラに届かない）。読みモデルのように取りこぼせない用途では、`metadata[:version]` を使って重複を無視し、欠落をイベントストアから埋める。その実装例が [サンプルアプリの `Projections`](examples/auction_house/app/projections/projections.rb) にある。

## コンポーネント

### PersistentActor

集約の定義。インスタンスはRactorを持たない軽いハンドルで、コマンドはシャードRactorに転送される。

```ruby
class MyActor < Rakka::PersistentActor
  def initial_state       # 初期状態
  def handle(cmd, state)  # コマンド処理 → [:persist, event, ...] | [:reject, reason] | [:noop]
  def apply_event(e, s)   # イベント適用 → 新しい状態
end
```

`send_command_sync` の戻り値は `[:ok, event]` / `[:rejected, reason]` / `[:noop]`。
`handle` / `apply_event` が例外を投げた場合は `Rakka::ActorCrashed` が呼び出し側に上がる。

### ActorSystem

シャードRactorの集合。`stream_id` のハッシュでシャード（ホーム）を決め、同じ集約のコマンドは1つのシャードで直列に処理される。

```ruby
Rakka.system.stats
# => { shard_count: 4, active_count: 1234, queued: 0, dropped: 0,
#      migrations: 0, relocated: 0, restarts: {}, shards: [...] }

# 明示的に作ることもできる
system = Rakka::ActorSystem.new(event_store: store, shard_count: 2)
account = BankAccount.new("account-123", system: system)
```

デフォルトの `Rakka.system` は最初のコマンドで起動する。

### メールボックス

メールボックスはアクターごとに持つ。シャードは、メッセージを持つアクターを順番に `throughput` 件ずつ処理する（Akkaのディスパッチャと同じ方式）。あるアクターにコマンドが大量に溜まっていても、同じシャードの他のアクターは `throughput` 件ごとに順番が回ってくる。同じアクター宛てのメッセージは必ず到着順に処理される。

`mailbox_capacity` を設定すると、溜まっているメッセージがその数に達したアクターは新しいメッセージを受け付けなくなる。`send_command_sync` は `Rakka::MailboxFull` を上げ、`send_command` は警告を出して破棄する。処理が追いつかないときにメモリを使い続ける代わりに、送り手に過負荷を伝える。

### リバランス

ハッシュでの割り当ては、アクターが多ければ均等になるが、忙しいアクターがたまたま同じシャードに集まると、そのシャードだけが詰まって他のコアが空く。ActorSystemは各シャードの負荷を見て、溜まっているアクターをメールボックスごと空いているシャードへ移す。

いつ・どれを移すかに調整用の設定は無い。各シャードがメッセージ1件の処理時間とアクターの復元時間を実測していて、次の条件を満たすときだけ移す。

- 手が空くシャードがある（全シャードが忙しいときは、移しても手間のぶん遅くなるだけなので何もしない）
- 移動の手間（復元時間を含む）を払っても、そのアクターの処理が今のシャードで待つより早く終わる

負荷を調べる間隔も、偏りがある間は短く（10ms）、無ければ長く（最大0.5秒）なる。

- 移動中もアクターごとのメッセージ順序は保たれる
- 状態は運ばず、移動先がスナップショットとイベントから復元する
- 1つのアクターにだけ負荷が集中している場合は移さない（1アクターは1シャードでしか処理できない）

```ruby
system.migrate("BankAccount-123", 2)   # 手動で移すこともできる
system.shard_index("BankAccount-123")  # => 2
```

### アクター間メッセージング

`handle` の中で他のアクターのハンドルを作り、非同期のコマンドを送れる。

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

- 送信は、そのコマンドのイベントが永続化された後に行われる。コマンドが例外で落ちた場合は送られない
- 配送は at-most-once。永続化の直後にプロセスが落ちると失われるので、確実に届けたい連携はイベントハンドラ（`Rakka.subscribe`）側で行う
- `handle` の中で返信を待つこと（`send_command_sync` / `state`）はできない

### EventStore

イベントの永続化を担当。追記は期待バージョンつきの楽観ロックで、競合したらシャードが状態を読み直してコマンドを判定し直す。

| Store | 用途 | 特徴 |
|-------|------|------|
| `Memory` | テスト | Ractor内のHashに保存 |
| `Postgres` | 本番 | シャードごとに1コネクション、`UNIQUE(stream_id, position)` で競合検出 |

### スナップショット

イベントが増えると、復元（Passivation後、再起動後、リバランス後）のたびに全イベントを再生するのが重くなる。Rakkaは `snapshot_every` イベントごとにアクターの状態を保存し、復元時はそこから後のイベントだけを再生する。

```ruby
class Ledger < Rakka::PersistentActor
  snapshot_every 500    # このクラスだけ間隔を変える（nil で無効）
  snapshot_schema 2     # state の形や apply_event の意味を変えたら上げる
end
```

- スナップショットはストリームごとに最新の1つだけ。イベントは消さない
- `snapshot_schema` の番号が違う古いスナップショットは使われず、イベントの再生で作り直される
- PostgreSQLでは `rakka_snapshots` テーブルに保存する（`Postgres.create_schema` が作成）。state は Marshal で保存するので、Marshal できるオブジェクトであること

### Passivation

メモリ上のアクター状態は、`passivate_after` 秒アイドルが続くか、シャードの保持数が `max_actors_per_shard` を超えると解放される。次のコマンドでイベントから復元される。

```ruby
account.stop  # 明示的に解放
```

### 障害処理

| 層 | きっかけ | 動作 |
|----|---------|------|
| アクター | `handle` / `apply_event` の例外 | そのアクターの状態だけ破棄。同じシャードの他のアクターは影響なし |
| シャード | シャードRactorの異常終了 | `Supervisor` が再起動（デフォルト3回/60秒まで）。アクターは順次復元 |

### EventBus

イベントが永続化された後に、メインRactorのスレッドでハンドラを呼び出す。非同期コマンド（`send_command`）でも呼ばれる。

```ruby
Rakka.subscribe(SomeEvent) { |event, metadata| ... }
Rakka.subscribe_all { |event, metadata| ... }  # 全イベント

# ハンドラの呼び出しを包む（rakka-railsはRailsのexecutorで包んでいる）
Rakka.event_bus.around_publish { |publish| SomeLock.synchronize { publish.call } }
```

- 配送は at-most-once（「基本的な使い方 4」を参照）
- ハンドラが例外を投げても、警告を出して次のハンドラへ進む

## 開発

どれもリポジトリ直下から始める。

```bash
# PostgreSQL起動（Docker）。無くてもPostgreSQL以外のテストは動く（該当スペックはスキップ）
docker compose up -d

# rakka-core
cd rakka-core
bundle install
bundle exec rspec

# rakka-rails（最小のRailsアプリを起動して、Railtieとジェネレータを検証する）
cd rakka-rails
bundle install
bundle exec rspec

# サンプルアプリ
cd examples/auction_house
bundle install
bin/rails db:setup
bin/rails test
```

### デモスクリプト（rakka-core/examples）

`cd rakka-core && ruby examples/<ファイル名>` で実行する。`postgres_demo.rb` 以外はPostgreSQL不要。

| ファイル | 内容 |
|---|---|
| `bank_account.rb` | 基本の集約（入金・出金・残高不足の拒否・復元） |
| `async_demo.rb` | 非同期コマンドとイベントハンドラ |
| `event_handler_demo.rb` | イベントの種類ごとのハンドラと全イベントのハンドラ |
| `passivation_demo.rb` | アイドルなアクターの解放と、イベントからの復元 |
| `supervisor_demo.rb` | アクター単位のクラッシュと、シャードRactorの再起動 |
| `transfer_demo.rb` | アクター間メッセージング（口座間の送金） |
| `many_actors_demo.rb` | 多数のアクターを少数のRactorに載せたときのメモリと処理速度（引数でアクター数） |
| `postgres_demo.rb` | PostgreSQLのEventStore、復元、楽観ロック |

## アーキテクチャ

```
 BankAccount.new(id)          ハンドル（Ractorなし）
        │ command
        ▼
┌──────────────────────────────────────────────┐
│ ActorSystem   crc32(stream_id) % shard_count │
└───────┬──────────────────────┬───────────────┘
        ▼                      ▼
┌────────────────┐     ┌────────────────┐
│ Shard (Ractor) │     │ Shard (Ractor) │  … コア数ぶん（Supervisorが監視）
│ actors = {     │     │ actors = {     │
│  id => state,  │     │  id => state,  │  ← アクターはここのエントリ
│  id => state } │     │  id => state } │
│ Journal        │     │ Journal        │
└───┬────────┬───┘     └───┬────────┬───┘
    │        │ append(expected_version)
    │        ▼             │        ▼
    │   ┌──────────────────────────────┐
    │   │ EventStore (PostgreSQL等)    │
    │   └──────────────────────────────┘
    ▼ publish              ▼
┌─────────────────┐     ┌──────────────────────┐
│ EventPublisher  │────▶│  EventBus            │
│   (Port)        │     │  (Main Thread)       │
└─────────────────┘     └──────────────────────┘
```

### Railsで使う場合

```bash
rails generate rakka:install          # マイグレーション（events / snapshots）と config/initializers/rakka.rb
rails db:migrate
rails generate rakka:aggregate Order  # app/aggregates/order.rb
```

`config/initializers/rakka.rb` の `config.rakka` に書いた設定（`shard_count` / `passivate_after` / `max_actors_per_shard` / `throughput` / `mailbox_capacity` / `snapshot_every` / `rebalance`）がRakka本体に渡る。接続先は `database.yml` から取る。既存のアプリにスナップショット用のテーブルだけ足す場合は `rails rakka:create_schema`（無いテーブルだけ作る）。

```ruby
# config/initializers/rakka.rb
Rails.application.config.rakka = {
  shard_count: 4,
  snapshot_every: 100
}

Rakka.subscribe_all { |event, metadata| Projections.apply(event, metadata) }
```

rakka-railsが自動で行うこと:

- イベントハンドラをRailsのexecutorで包んで呼ぶ（DB接続の返却、コードの再読み込みとの排他）
- 開発環境でコードを再読み込みする前にActorSystemを止める。次のコマンドで作り直され、アクターはイベントから戻る（止めないと、シャードに残った古いクラスのアクターで最初のコマンドが失敗する）

気をつけること:

- `handle` / `apply_event` はシャードRactorの中で動く。ActiveRecordやグローバルな状態には触れず、引数だけを使う
- リクエストやテストの中で読みモデルの反映を待つときは、クエリキャッシュに注意する（同じSQLの結果がキャッシュされ、いつまでも変わらないように見える）。`ActiveRecord::Base.uncached` の中で確かめる
- リバランスが働くのはプロセス内のシャード間だけ（プロセスをまたいだ移動はしない）
- シャードRactorはプロセスごとに持つ。Pumaのクラスタモードでは各ワーカーが独立したActorSystemになる
- ワーカーをまたいだ同時書き込みは楽観ロックで検出・再試行されるので整合性は保たれる（メモリ上のアクターは「単一ライターの保証」ではなく「状態キャッシュ + プロセス内の直列化」）
- PostgreSQLのコネクション数は、プロセスあたり `shard_count + 1`

実際に動くアプリは [`examples/auction_house`](examples/auction_house) を参照。

## Ractor制約

- Ractor間で渡せるのは **shareable objects** のみ
  - 数値、Symbol、frozen String、`Data.define`
- 可変オブジェクトの共有不可 → 競合状態を設計レベルで防止
- `pg` gemはRactor safe、`sqlite3`/`mysql2`はRactor unsafe

## ライセンス

MIT（[LICENSE](LICENSE)）
