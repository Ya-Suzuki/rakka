---
title: ホーム
nav_order: 1
permalink: /
---

# Rakka
{: .fs-9 }

Ruby 4.0 の Ractor で動く、アクター型のイベントソーシングライブラリ。
{: .fs-6 .fw-300 }

[はじめる](getting-started.html){: .btn .btn-primary .mr-2 } [GitHub](https://github.com/Ya-Suzuki/rakka){: .btn }

---

名前の由来は **Ra**ctor + **Akka**。Akka と同じく、集約（エンティティ）1つを1つのアクターとして扱い、コマンドをイベントとして永続化して、状態はイベントから作り直します。

```ruby
class BankAccount < Rakka::PersistentActor
  Deposit = Data.define(:amount)
  MoneyDeposited = Data.define(:amount)

  def initial_state = { balance: 0 }
  def deposit(amount) = send_command_sync(Deposit[amount])
  def balance = state[:balance]

  def handle(command, state)
    case command
    in Deposit(amount:) then [:persist, MoneyDeposited[amount]]
    end
  end

  def apply_event(event, state)
    case event
    in MoneyDeposited(amount:) then state.merge(balance: state[:balance] + amount)
    end
  end
end

account = BankAccount.new("account-123")
account.deposit(1000)
account.balance # => 1000（プロセスを再起動しても、イベントから同じ状態に戻る）
```

## 特徴

| | |
|---|---|
| 軽量アクター | アクターは Ractor ではなく、シャード Ractor の中のエントリ。数万アクターでも Ractor はコア数程度 |
| アクターごとのメールボックス | 公平なスケジューリング、容量の上限、アクター間メッセージング |
| リバランス | 負荷が偏ると、溜まっているアクターを空いているシャードへ自動で移す |
| 楽観ロック | 複数プロセスから同じ集約に書いても整合する |
| スナップショット | 一定イベントごとに状態を保存し、復元を速くする |
| Let it crash | アクターの例外は状態を捨てて復元、シャードの異常終了は自動で再起動 |
| Rails 統合 | ジェネレータ、`database.yml` からの接続設定、コード再読み込みへの対応 |

## このサイトの構成

- [はじめに](getting-started.html) — インストールから最初の集約まで
- [仕組み](concepts/) — アクターと Ractor の関係、メールボックス、リバランス、永続化、障害処理
- [Rails で使う](rails.html) — rakka-rails の使い方と注意点
- [サンプルアプリ](sample-app.html) — オークションを題材にした Rails アプリ
- [よくある疑問](faq.html) — Ractor を使う意味、Akka や Erlang との違い など
- [開発](development.html) — テストとデモスクリプト
