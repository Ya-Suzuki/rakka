---
title: サンプルアプリ
nav_order: 5
---

# サンプルアプリ（Auction House）
{: .no_toc }

[`examples/auction_house`](https://github.com/Ya-Suzuki/rakka/tree/main/examples/auction_house) は、ネットオークションを題材にした Rails 8.1 のアプリです。

1. TOC
{:toc}

## 題材にオークションを選んだ理由

- **1つの出品に入札が集中する**: 「最高額を読んで、それより高ければ受け付ける」をロックなしで正しく処理する必要がある。1出品 = 1アクターにすると、入札がメールボックスに並び1件ずつ判断される
- **履歴そのものに価値がある**: 誰がいつ幾らで入札したかは、現在の価格だけを持つ設計では失われる。イベントソーシングならすべて残り、任意の時点の状態も再現できる
- **見せ方の違う読みモデルが複数ある**: 出品一覧と入札者ランキングを、同じイベントから作る

## 動かし方

```bash
docker compose up -d          # リポジトリ直下で（PostgreSQL）
cd examples/auction_house
bundle install
bin/rails db:setup            # DB作成 + マイグレーション + サンプルデータ
bin/rails server
```

http://localhost:3000 を開き、右上の「あなた」で名前を切り替えながら出品・入札できます。

## 同時入札

```bash
bin/rails auction:bidding_war     # 20人 × 10回、同じ出品に同時に入札
```

```
入札 200件（1670件/秒）
  受理: 36件
  拒否: 164件（最低入札額に届いていません）

確認
  受理した入札 = 記録された入札イベント: OK
  入札額は常に前の最高額 + 100円以上: OK
  現在価格 = 受理した最高額（6300円）: OK
```

各スレッドは「今の価格を見て、それより高い額で入札」しますが、見てから届くまでの間に他の人の入札が先に処理されます。アクターが1件ずつ判断するので、古い価格を見て出した入札は正しく拒否されます。アプリ側にロックはありません。

## タイムトラベル

出品の詳細画面には、その出品のイベントがすべて並びます。行をクリックすると、その時点の状態を表示します。過去の状態はどこにも保存しておらず、イベントを `apply_event` で順に適用し直して作っています。

## 読みモデル

一覧とランキングは、書き込みとは別のテーブル（`auction_listings` / `bids`）から表示しています。イベントを購読して更新する [`Projections.apply`](https://github.com/Ya-Suzuki/rakka/blob/main/examples/auction_house/app/projections/projections.rb) は、ストリームごとに反映済みの version を `stream_checkpoints` テーブルに持ち、読みモデルと同じトランザクションで更新します。

| 起きること | 動作 |
|---|---|
| 同じイベントが2回届いた | version が反映済みなので無視する |
| 途中のイベントが届かなかった（発行前にプロセスが落ちた等） | 次のイベントが届いた時点で、抜けた分をイベントストアから読んで埋める |
| 複数のプロセスが同じ出品のイベントを発行した | チェックポイントの行ロックで順に反映される |
| 集計方法を変えた・読みモデルを足した | `bin/rails projections:rebuild` で全イベントから作り直す |

Rakka のイベント配送は at-most-once ですが、この形にすれば読みモデルは取りこぼしません。

## 集約のテスト

`handle` / `apply_event` は純粋関数なので、「過去のイベント + コマンド → 新しいイベント」の形で、DB もアクターも使わずにテストできます。

```ruby
def decide(given, command)
  actor = Auction.behavior("test")
  state = given.reduce(actor.initial_state) { |s, event| actor.apply_event(event, s) }
  actor.handle(command, state)
end

test "即決価格以上の入札は、入札と終了の2つのイベントになる" do
  given = [Auction::Opened["カメラ", "alice", 1000, 3000]]

  assert_equal [:persist, Auction::BidPlaced["bob", 3000], Auction::Closed["bob", 3000, "buyout"]],
               decide(given, Auction::PlaceBid["bob", 9999])
end
```
