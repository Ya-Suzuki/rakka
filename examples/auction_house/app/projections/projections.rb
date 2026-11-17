# イベント → 読みモデル。
#
# ライブ更新（Rakka.subscribe_all から呼ばれる）も、作り直し（rebuild!）も同じ
# apply を通る。ストリームごとに「どのversionまで反映したか」を stream_checkpoints に
# 持ち、同じトランザクションで読みモデルと一緒に更新するので:
#
# - 同じイベントが2回届いても2回反映しない（作り直しとライブ更新が重なっても大丈夫）
# - 途中のイベントが届かなかったら（プロセスが落ちた等）、イベントストアから読んで埋める
# - 複数プロセスが同じストリームのイベントを発行しても、行ロックで順番に反映される
module Projections
  module_function

  def all = [AuctionListingProjection, BidProjection]

  def apply(event, metadata)
    stream_id = metadata.fetch(:stream_id)
    version = metadata.fetch(:version)

    ActiveRecord::Base.transaction do
      StreamCheckpoint.insert({ stream_id:, version: 0 }) # 無ければ作る（あれば何もしない）
      checkpoint = StreamCheckpoint.lock.find(stream_id)
      next if version <= checkpoint.version

      missed = StoredEvent.for_stream(stream_id).where(position: checkpoint.version...(version - 1))
      missed.each { |stored| project(stored.event, metadata_of(stored)) }
      project(event, metadata)

      checkpoint.update!(version:)
    end
  end

  # 読みモデルを全部消して、イベントストアの全イベントから作り直す。
  # 新しい読みモデルを足したときも、これで過去の分が埋まる
  def rebuild!
    ActiveRecord::Base.transaction do
      # 作り直している間のライブ更新は待たせ、終わってから（反映済みとして）読み飛ばさせる
      ActiveRecord::Base.connection.execute("LOCK TABLE stream_checkpoints IN EXCLUSIVE MODE")
      all.each(&:reset!)
      StreamCheckpoint.delete_all

      StoredEvent.ordered.each { |stored| apply(stored.event, metadata_of(stored)) }
    end
  end

  # すべてのイベントが読みモデルに反映されたか。ポーリングで呼ばれるので、
  # クエリキャッシュ（リクエストやテストの中では有効）を通さずに数える
  def caught_up?
    ActiveRecord::Base.uncached { StreamCheckpoint.sum(:version) == StoredEvent.count }
  end

  def wait_until_caught_up(timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until caught_up?
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        raise "読みモデルへの反映が#{timeout}秒以内に終わりませんでした。購読より前に書かれたイベントがあるなら " \
              "bin/rails projections:rebuild で作り直してください"
      end

      sleep 0.02
    end
  end

  def project(event, metadata)
    all.each { |projection| projection.apply(event, metadata) }
  end

  def metadata_of(stored)
    { stream_id: stored.stream_id, actor_id: stored.stream_id.split("-", 2).last,
      version: stored.version, recorded_at: stored.created_at }
  end
end
