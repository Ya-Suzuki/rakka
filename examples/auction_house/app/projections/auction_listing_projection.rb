module AuctionListingProjection
  module_function

  def reset! = AuctionListing.delete_all

  def apply(event, metadata)
    auction_id = metadata.fetch(:actor_id)
    at = metadata[:recorded_at] || Time.current

    case event
    in Auction::Opened(title:, seller:, starting_price:, buyout_price:)
      AuctionListing.create!(auction_id:, title:, seller:, starting_price:, buyout_price:,
                             status: "open", opened_at: at)
    in Auction::BidPlaced(bidder:, amount:)
      listing = AuctionListing.find_by!(auction_id:)
      listing.update!(current_price: amount, leader: bidder, bid_count: listing.bid_count + 1)
    in Auction::Closed(winner:, price:, reason:)
      AuctionListing.find_by!(auction_id:).update!(
        status: winner ? "sold" : "unsold", winner:, final_price: price, close_reason: reason, closed_at: at
      )
    else
      nil
    end
  end
end
