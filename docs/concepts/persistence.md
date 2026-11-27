---
title: 永続化と復元
parent: 仕組み
nav_order: 4
---

# 永続化と復元
{: .no_toc }

1. TOC
{:toc}

## EventStore と Journal

EventStore はイベントの保存先です。各シャード Ractor は EventStore から自分専用の Journal（PostgreSQL ならコネクション1本）を受け取って読み書きします。

| Store | 用途 | 特徴 |
|---|---|---|
| `Memory` | テスト | Ractor 内の Hash に保存 |
| `Postgres` | 本番 | シャードごとに1コネクション（プロセスあたり `shard_count + 1` 本） |

## 楽観ロック

イベントの追記には、「このストリームは今 version N のはず」という期待値をつけます。PostgreSQL では `UNIQUE(stream_id, position)` が食い違いを検出します。

食い違ったとき（別のプロセスが先に書いたとき）は、シャードがメモリ上の状態を捨て、最新のイベントから作り直してコマンドを判定し直します（最大3回）。そのため、Puma のワーカーなど複数のプロセスが同じ集約に書いても整合性は保たれます。

{: .note }
メモリ上のアクターは「単一ライターの保証」ではなく、「状態のキャッシュ + プロセス内の直列化」です。正しさは楽観ロックが守ります。

## スナップショット

イベントが増えると、復元のたびに全イベントを再生するのが重くなります。Rakka は `snapshot_every`（既定 100）イベントごとに状態を保存し、復元時はそこから後のイベントだけを再生します。PostgreSQL で 10,000 イベントのストリームを復元する時間は、約 28ms から 0.3ms になりました。

```ruby
class Ledger < Rakka::PersistentActor
  snapshot_every 500    # このクラスだけ間隔を変える（nil で無効）
  snapshot_schema 2     # state の形や apply_event の意味を変えたら上げる
end
```

- スナップショットはストリームごとに最新の1つだけ。イベントは消さない
- `snapshot_schema` の番号が違う古いスナップショットは使われず、イベントの再生で作り直される
- 消しても壊れても困らないキャッシュとして扱う。保存の失敗は警告だけ、読めないものは無いものとして扱う
- PostgreSQL では `rakka_snapshots` テーブルに Marshal で保存する。state は Marshal できるオブジェクトであること

{: .warning }
`apply_event` の結果が変わる変更をしたら、`snapshot_schema` を上げてください。上げないと、古い意味で作られた状態から復元されます。

## Passivation

メモリ上のアクターは、`passivate_after` 秒アイドルが続くか、シャードの保持数が `max_actors_per_shard` を超えると解放されます。次のコマンドで、スナップショットとイベントから復元されます。

```ruby
account.stop # 明示的に解放する
```
