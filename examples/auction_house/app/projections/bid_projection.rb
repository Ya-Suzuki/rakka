module BidProjection
  module_function

  def reset! = Bid.delete_all

  def apply(event, metadata)
    return unless event in Auction::BidPlaced(bidder:, amount:)

    Bid.create!(auction_id: metadata.fetch(:actor_id), version: metadata.fetch(:version),
                bidder:, amount:, placed_at: metadata[:recorded_at] || Time.current)
  end
end
