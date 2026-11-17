---
title: Rails で使う
nav_order: 4
---

# Rails で使う
{: .no_toc }

1. TOC
{:toc}

## セットアップ

```ruby
# Gemfile
gem "rakka", github: "Ya-Suzuki/rakka", glob: "rakka-core/*.gemspec"
gem "rakka-rails", github: "Ya-Suzuki/rakka", glob: "rakka-rails/*.gemspec"
```

```bash
bin/rails generate rakka:install          # マイグレーション（events / snapshots）と config/initializers/rakka.rb
bin/rails db:migrate
bin/rails generate rakka:aggregate Order  # app/aggregates/order.rb
```

接続先は `database.yml` から取ります。既存のアプリにテーブルだけ足すなら `bin/rails rakka:create_schema`（無いテーブルだけ作る）、今の設定は `bin/rails rakka:info` で確認できます。

## 設定

```ruby
# config/initializers/rakka.rb
Rails.application.config.rakka = {
  shard_count: 4,
  snapshot_every: 100,
  database_config_name: :primary, # database.yml のどの設定を使うか
  auto_configure: true            # false にすると Rakka.configure を自分で書く
}

# イベントを読みモデルに反映する
Rakka.subscribe_all { |event, metadata| Projections.apply(event, metadata) }
```

`config.rakka` に書いた `shard_count` / `passivate_after` / `max_actors_per_shard` / `throughput` / `mailbox_capacity` / `snapshot_every` / `rebalance` が Rakka 本体に渡ります。意味は [はじめに](getting-started.html#設定する) の表のとおりです。

## rakka-rails が自動で行うこと

| | |
|---|---|
| 設定の反映 | `config/initializers` を読み終えた後（`after_initialize`）に反映する |
| executor | イベントハンドラを Rails の executor で包んで呼ぶ。DB 接続の返却と、コードの再読み込みとの排他を Rails に任せる |
| コードの再読み込み | 開発環境で再読み込みする前に ActorSystem を止める。次のコマンドで作り直され、アクターはイベントから戻る |

再読み込みへの対応が無いと、シャードに残った古いクラスのアクターに新しいクラスのコマンドが届き、再読み込み後の最初のコマンドが必ず失敗します。

## 本番での構成

- シャード Ractor はプロセスごとに持ちます。Puma のクラスタモードでは、各ワーカーが独立した ActorSystem になります（最初のコマンドで起動するので、fork の後に作られます）
- ワーカーをまたいだ同時書き込みは、[楽観ロック](concepts/persistence.html#楽観ロック) で検出してやり直すので整合性は保たれます
- PostgreSQL のコネクション数は、プロセスあたり `shard_count + 1` 本です。ActiveRecord のコネクションプールとは別に数えてください

## 気をつけること

{: .warning }
`handle` / `apply_event` はシャード Ractor の中で動きます。ActiveRecord やグローバルな状態には触れず、引数だけを使ってください。

- **集約は `app/aggregates/` に置く**: コマンドとイベントはクラスの中で `Data.define` する
- **読みモデルの反映を待つときはクエリキャッシュに注意する**: リクエストやテストの中では、同じ SQL の結果がキャッシュされ、いつまでも変わらないように見えます。`ActiveRecord::Base.uncached { ... }` の中で確かめてください
- **テストではトランザクションで巻き戻らない**: イベントは Rakka が自分のコネクションで書くので、Rails のトランザクショナルテストでは消えません。サンプルアプリの `test/test_helper.rb` のように、テストごとにテーブルを空にします

実際に動く例は [サンプルアプリ](sample-app.html) を参照してください。
