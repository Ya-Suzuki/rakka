# Rakka

RubyのRactorを使ったアクターベースのイベントソーシングライブラリ。

名前の由来: **Ra**ctor + **Akka** = **Rakka**

## コンセプト

- **Actor**: コマンドを受け取り、イベントを生成し、状態を更新する独立した処理単位
- **Event Sourcing**: 状態の変更をイベントとして記録し、イベントの再生で状態を復元可能にする

## 使い方

```ruby
require 'rakka'

# EventStoreを起動
event_store = Rakka::EventStore.start

# Actorを生成（初期状態とEventStoreを渡す）
actor = Rakka::Actor.spawn({ balance: 1000 }, event_store)

# コマンドを送信
actor.send({ type: :withdraw, amount: 200 })
```

## 開発

```bash
bundle install
bundle exec rspec
```

## License

MIT
