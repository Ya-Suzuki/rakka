---
title: 開発
nav_order: 7
---

# 開発
{: .no_toc }

1. TOC
{:toc}

## 構成

```
rakka/
├── rakka-core/               # コアライブラリ (gem "rakka")
├── rakka-rails/              # Rails統合 (gem "rakka-rails")
├── examples/auction_house/   # Railsのサンプルアプリ
└── docs/                     # このサイト（GitHub Pages）
```

## テスト

どれもリポジトリ直下から始めます。PostgreSQL が無くても、PostgreSQL を使うスペック以外は動きます。

```bash
docker compose up -d   # PostgreSQL

# rakka-core
cd rakka-core && bundle install && bundle exec rspec

# rakka-rails（最小の Rails アプリを起動して、Railtie とジェネレータを検証する）
cd rakka-rails && bundle install && bundle exec rspec

# サンプルアプリ
cd examples/auction_house && bundle install && bin/rails db:setup && bin/rails test
```

## デモスクリプト

`cd rakka-core && ruby examples/<ファイル名>` で実行します。`postgres_demo.rb` 以外は PostgreSQL 不要です。

| ファイル | 内容 |
|---|---|
| `bank_account.rb` | 基本の集約（入金・出金・残高不足の拒否・復元） |
| `async_demo.rb` | 非同期コマンドとイベントハンドラ |
| `event_handler_demo.rb` | イベントの種類ごとのハンドラと全イベントのハンドラ |
| `passivation_demo.rb` | アイドルなアクターの解放と、イベントからの復元 |
| `supervisor_demo.rb` | アクター単位のクラッシュと、シャード Ractor の再起動 |
| `transfer_demo.rb` | アクター間メッセージング（口座間の送金） |
| `many_actors_demo.rb` | 多数のアクターを少数の Ractor に載せたときのメモリと処理速度（引数でアクター数） |
| `postgres_demo.rb` | PostgreSQL の EventStore、復元、楽観ロック |

## このサイトを編集する

ページは `docs/` の Markdown です。各ページの「このページを編集」から GitHub 上で直接編集できます。`main` に入ると GitHub Pages が自動で作り直します。

新しいページは、先頭に front matter を書きます。

```markdown
---
title: ページ名
nav_order: 8
parent: 仕組み   # 「仕組み」の下に置く場合
---
```
