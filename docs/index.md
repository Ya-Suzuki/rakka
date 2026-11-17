---
title: ホーム
nav_order: 1
permalink: /
layout: landing
description: 状態は散っても、イベントから何度でも咲く。Ruby 4.0 の Ractor で動く、アクター型のイベントソーシングライブラリ。
---

```ruby
class BankAccount < Rakka::PersistentActor
  Deposit        = Data.define(:amount)
  MoneyDeposited = Data.define(:amount)

  def initial_state = { balance: 0 }

  # コマンド → イベント（判断）
  def handle(command, state)
    case command
    in Deposit(amount:) then [:persist, MoneyDeposited[amount]]
    end
  end

  # イベント → 状態（純粋関数）
  def apply_event(event, state)
    case event
    in MoneyDeposited(amount:)
      state.merge(balance: state[:balance] + amount)
    end
  end

  def deposit(amount) = send_command_sync(Deposit[amount])
  def balance = state[:balance]
end

account = BankAccount.new("account-123")
account.deposit(1000)
account.balance # => 1000（再起動しても、イベントから同じ姿に）
```
