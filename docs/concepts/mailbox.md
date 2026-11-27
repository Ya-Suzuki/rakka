---
title: メールボックスとメッセージング
parent: 仕組み
nav_order: 2
---

# メールボックスとメッセージング
{: .no_toc }

1. TOC
{:toc}

## アクターごとのメールボックス

シャードに届いたメッセージは、まず宛先アクターのメールボックスに振り分けられます。シャードはメッセージを持つアクターを順に回り、1つのアクターにつき `throughput` 件（既定 5）処理したら次のアクターに移ります。Akka のディスパッチャと同じ方式です。

`throughput: 2` で、`busy` に6件溜めたあと `other` に1件送ったときの処理順:

```
busy busy other busy busy busy busy
```

1つのアクターにコマンドが溜まっても、同じシャードの他のアクターは `throughput` 件ごとに順番が回ってきます。同じアクター宛てのメッセージは、必ず到着順に処理されます。

{: .note }
切り替わるのはメッセージの合間だけです。`handle` の中で長くブロックすると、その間は同じシャードの他のアクターも待たされます。

## 容量の上限

`mailbox_capacity` を設定すると、溜まっているメッセージがその数に達したアクターは新しいメッセージを受け付けません。処理が追いつかないときにメモリを使い続ける代わりに、送り手に過負荷を伝えます。

| 送り方 | 満杯のとき |
|---|---|
| `send_command_sync` | `Rakka::MailboxFull` |
| `send_command` | 警告を出して破棄 |

## アクター間メッセージング

`handle` の中で他のアクターのハンドルを作り、非同期のコマンドを送れます。

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

- 送信は、そのコマンドのイベントが永続化された後に行われる。例外で落ちた回や、競合でやり直した回の分は送られない
- 配送は at-most-once。永続化の直後にプロセスが落ちると失われるので、確実に届けたい連携はイベントの購読側で行う
- `handle` の中で返信を待つこと（`send_command_sync` / `state`）はできない。シャードごと止まり、相手が同じシャードならデッドロックするため
