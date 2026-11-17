class BidsController < ApplicationController
  def create
    auction_id = params[:auction_id]

    case Auction.new(auction_id).bid(current_user, params[:amount].to_i)
    in [:ok, [Auction::BidPlaced, Auction::Closed => closed]]
      redirect_to auction_path(auction_id), notice: "即決価格 #{helpers.yen(closed.price)} で落札しました！"
    in [:ok, Auction::BidPlaced => bid]
      redirect_to auction_path(auction_id), notice: "#{helpers.yen(bid.amount)} で入札しました"
    in [:rejected, reason]
      redirect_to auction_path(auction_id), alert: helpers.rejection_message(reason)
    end
  end
end
