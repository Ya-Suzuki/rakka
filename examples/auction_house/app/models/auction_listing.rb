class AuctionListing < ApplicationRecord
  STATUS_LABELS = { "open" => "受付中", "sold" => "落札", "unsold" => "不成立" }.freeze

  def open? = status == "open"
  def price = current_price || starting_price
  def status_label = STATUS_LABELS.fetch(status)
end
