# Rakkaが書いたイベント（rakka_events）を読むためのモデル。書き込みはRakkaだけが行う
class StoredEvent < ApplicationRecord
  self.table_name = "rakka_events"

  scope :ordered, -> { order(:stream_id, :position) }
  scope :for_stream, ->(stream_id) { where(stream_id:).order(:position) }

  def readonly? = true

  # 1始まりのversion（Rakkaのversion = そのイベントまでのイベント数）
  def version = position + 1

  def event
    event_type.constantize.new(**data.symbolize_keys)
  end
end
