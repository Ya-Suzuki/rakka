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

**アクター ≠ Ractor**。Ractorはシャード数（≒コア数）だけ作り、アクターはシャードRactor内のHashエントリ（behavior + state + version）として同居する（Akkaのディスパッチャ方式）。アクター数を増やしてもRactorは増えない。アクターの置き場所は `crc32(stream_id)` で決まるホームが基本で、負荷が偏ると空いているシャードへ移される。

### コアコンポーネント (rakka-core/lib/rakka/)

| ファイル | 役割 |
|---------|------|
| `persistent_actor.rb` | 集約の定義（`initial_state` / `handle` / `apply_event`）と、コマンドを転送するだけの軽いハンドル。Ractorは持たない |
| `actor_system.rb` | シャードRactorの起動、ルーティング（ホーム + 移動済みアクターの表）、返信待ちの管理、アクター間メッセージの配送、リバランス |
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
    ↓ activate: メモリに無ければ スナップショット + それ以降のイベントから復元
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
- `mailbox_capacity`（デフォルトnil=無制限）を超えたメッセージは受け付けない。同期呼び出しは `MailboxFull`、非同期は警告を出して破棄
- `[:command]` / `[:get_state]` / `[:passivate]` はメールボックス経由（アクターごとに到着順）。`[:tick]` / `[:stats]` / `[:stop]` はシャード宛てで即時処理

### アクター間メッセージング

- `handle` の中で他のアクターのハンドルを作り、`send_command` を使うメソッドを呼ぶと送れる（`OtherActor.new(id).do_later(...)`）
- シャードRactor内では、ハンドルの送信先は `Ractor.current[:rakka_context]`（そのシャードの `Shard::Outbox`）になる
- Outboxに溜めたメッセージは、イベントの永続化が成功した後に router port → メインRactorのrouterスレッド → 宛先シャードの順で配送される。競合でやり直した回・クラッシュした回の分は送られない
- 配送は at-most-once（永続化の直後にプロセスが落ちると失われる）。確実に届けたい連携はイベントを購読する側（EventBus）で行う
- `handle` の中から `send_command_sync` / `state` は使えない（シャードが止まるため例外になる）。`apply_event` / `initial_state` からは送れない

### リバランス（アクターの移動）

- 調整用の設定は無い（`rebalance: false` で無効にできるだけ）。各シャードが実測する `service_time`（メッセージ1件の処理時間）と `activation_time`（アクター1つの復元時間）の移動平均から自動で決める
- 溜まり具合は件数ではなく「捌き切るまでの見込み時間」（未処理数 × `service_time`）で比べる
- 移す条件（`ActorSystem#rebalance`）:
  1. 最大と最小の差（gap）が移動コスト（`HANDOFF_OVERHEAD` + `activation_time`）より大きい
  2. 移動先は、移動が済む頃には手が空いている（ワークスティーリングと同じ。全シャードが忙しいときに移すと、手間のぶん全体が遅くなる）
  3. そのアクターの分（time）を移しても `gap - time > cost`、つまり今のシャードで待つより早く終わる。1つのアクターに集中している場合は gap ≒ time なので動かない
- 調べる間隔は `REBALANCE_INTERVAL`（10ms〜0.5s）の範囲で、偏りがある間は最短、無ければ倍々で延ばす
- 移動済みアクターは `@routes`（stream_id => シャード番号）で管理。`MAX_ROUTES` を超えたら古いものからホームに戻す
- `migrate` の手順（順序を保つための引き継ぎ）:
  1. 移動先に `[:expect]` → 引き継ぎが届くまで、そのアクター宛てを保留（`@parked`）
  2. ルートを切り替える（以降のメッセージは移動先で保留される）
  3. 移動元に `[:release]` → 状態を捨て、未処理メッセージを移動先に `[:adopt]` で渡す
  4. 移動先は「引き継いだ分 → 保留分」の順でメールボックスに入れ、メインに `[:adopted]` を通知（返信待ちの付け替え）
- 「送り先を調べて送る」と「ルートの切り替え」は同じロック（`ActorSystem#@lock`）の中で行う。これが崩れると順序が入れ替わる
- 移動中にシャードが落ちた場合: 移動元が落ちたらメインが移動先の保留を解く。移動先が落ちたら移動元が待っている呼び出しを `ShardUnavailable` で起こす
- 状態そのものは運ばない。移動先がイベントから復元する（万一2つのシャードが同じアクターを処理しても、楽観ロックが整合性を守る）

### EventStoreとJournal

- EventStoreは `connector`（shareable）を公開し、各シャードRactorが `connector.connect` で自分専用のJournalを持つ
- `journal.append(stream_id, expected_version, events)` はバージョンが食い違うと `ConcurrencyError`
- version = ストリーム内のイベント数。PostgreSQLでは `UNIQUE(stream_id, position)` が競合を検出する
- 競合時、シャードはキャッシュした状態を捨て、読み直してコマンドを判定し直す（複数プロセスから書いても整合する）

### スナップショット

- `snapshot_every`（デフォルト100）イベントごとに、シャードが `journal.save_snapshot(stream_id, schema, version, state)` で状態を保存する。ストリームごとに最新の1つだけ持つ
- 復元は `journal.recover(stream_id, schema)` の1回で「スナップショット + 以降のイベント」を受け取り、スナップショットの state から以降のイベントだけ再生する
- クラスごとの指定: `snapshot_every 500` / `snapshot_every nil`（無効）。`snapshot_schema 2` で番号を上げると、古い番号のスナップショットは無視される（state の形や `apply_event` の意味を変えたときに上げる）
- スナップショットは消しても壊れても困らないキャッシュ。保存の失敗は警告だけ、読めないものは無いものとして扱う
- PostgreSQLでは `rakka_snapshots` テーブルに Marshal で保存する（JSONだとキーの型やDataが戻らないため）

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
- `apply_event` の結果が変わる変更をしたら `snapshot_schema` を上げること（上げないと古い状態のスナップショットから復元される）
