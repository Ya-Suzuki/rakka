---
title: はじめに
nav_order: 2
---

# はじめに
{: .no_toc }

1. TOC
{:toc}

## 必要環境

| 項目 | 内容 |
|---|---|
| Ruby | 4.0 以上（`Ractor::Port` を使う） |
| データベース | PostgreSQL（`pg` gem）。Ractor から使えないドライバ（`sqlite3`、`mysql2`）には対応しない |
| Rails（rakka-rails） | 7.0 以上。サンプルアプリは 8.1 で確認 |

テストやデモではメモリ上の EventStore を使えるので、PostgreSQL は無くても動きます。

## インストール

まだ rubygems.org には公開していないので、リポジトリから参照します。

```ruby
# Gemfile
gem "rakka", github: "Ya-Suzuki/rakka", glob: "rakka-core/*.gemspec"

# Rails で使う場合
gem "rakka-rails", github: "Ya-Suzuki/rakka", glob: "rakka-rails/*.gemspec"
```

## 集約を定義する

`Rakka::PersistentActor` を継承し、3つのメソッドを書きます。

| メソッド | 役割 |
|---|---|
| `initial_state` | イベントが1つも無いときの状態 |
| `handle(command, state)` | コマンドを受け取り、何をするか決める。`[:persist, event, ...]` / `[:reject, reason]` / `[:noop]` を返す |
| `apply_event(event, state)` | イベントを状態に適用して、新しい状態を返す（純粋関数） |

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

  def deposit(amount) = send_command_sync(Deposit[amount])
  def withdraw(amount) = send_command_sync(Withdraw[amount])
  def balance = state[:balance]

  def handle(command, state)
    case command
    in Deposit(amount:)
      [:persist, MoneyDeposited[amount]]
    in Withdraw(amount:) if state[:balance] < amount
      [:reject, :insufficient_funds]
    in Withdraw(amount:)
      [:persist, MoneyWithdrawn[amount]]
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

{: .important }
コマンドとイベントは `Data.define` で定義します。Ractor の間で受け渡しできる不変のオブジェクトだからです。`handle` / `apply_event` はシャード Ractor の中で実行されるので、引数以外（グローバル変数、ActiveRecord など）には触れないでください。

## 設定する

```ruby
Rakka.configure do |c|
  # メモリ（テスト用）
  c.event_store = Rakka::EventStore::Memory.new

  # PostgreSQL（本番用）。テーブルは Rakka::EventStore::Postgres.create_schema で作れる
  # c.event_store = Rakka::EventStore::Postgres.new(host: "localhost", dbname: "myapp", user: "app", password: "...")
end
```

設定できる項目は次のとおりです。どれも省略できます。

| 設定 | 既定値 | 内容 |
|---|---|---|
| `shard_count` | コア数 | シャード Ractor の数。並列度を決める（アクター数とは無関係） |
| `passivate_after` | 300 | この秒数コマンドが来なかったアクターをメモリから解放する |
| `max_actors_per_shard` | 10,000 | 1シャードがメモリに保持するアクター数の上限（超えたら古いものから解放） |
| `throughput` | 5 | 1つのアクターを続けて処理するメッセージ数 |
| `mailbox_capacity` | 無制限 | 1アクターに溜められるメッセージ数 |
| `snapshot_every` | 100 | 何イベントごとにスナップショットを保存するか。`false` で無効 |
| `rebalance` | `true` | 負荷が偏ったらアクターを空いているシャードへ移す（調整は自動） |

## 使う

```ruby
account = BankAccount.new("account-123")
account.deposit(1000)  # => [:ok, #<data MoneyDeposited amount=1000>]
account.withdraw(5000) # => [:rejected, :insufficient_funds]
account.balance        # => 1000
```

`BankAccount.new` は Ractor もスレッドも持たない軽いハンドルで、何度作っても構いません。状態はシャード Ractor の中にあり、メモリに無ければイベントから復元されます。

| 呼び出し | 戻り値・例外 |
|---|---|
| `send_command_sync` | `[:ok, event]`（複数なら `[:ok, [e1, e2]]`）/ `[:rejected, reason]` / `[:noop]` |
| `send_command` | 返信を待たない（fire & forget） |
| `handle` / `apply_event` が例外を投げた | `Rakka::ActorCrashed` |
| メールボックスが満杯 | `Rakka::MailboxFull` |
| シャードが止まっている | `Rakka::ShardUnavailable` |

## イベントを購読する

```ruby
Rakka.subscribe(BankAccount::MoneyDeposited) do |event, metadata|
  # metadata: { stream_id: "BankAccount-account-123", actor_id: "account-123", version: 3 }
  puts "#{metadata[:actor_id]} に #{event.amount} 入金"
end

Rakka.subscribe_all { |event, metadata| ... } # すべてのイベント
```

{: .warning }
ハンドラへの配送は at-most-once で、同じプロセスの中だけで行われます。イベントを書いた直後にプロセスが落ちると、そのイベントはハンドラに届きません。読みモデルのように取りこぼせない用途での作り方は、[サンプルアプリ](sample-app.html#読みモデル) を参照してください。
