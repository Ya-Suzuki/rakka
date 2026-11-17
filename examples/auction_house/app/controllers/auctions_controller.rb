class AuctionsController < ApplicationController
  # 一覧とランキングは読みモデルから（書き込みとは別のテーブル）
  def index
    @listings = AuctionListing.order(opened_at: :desc)
    @leaderboard = Leaderboard.top
  end

  def create
    id = SecureRandom.alphanumeric(8).downcase

    case Auction.new(id).open(title: params[:title].to_s, seller: current_user,
                              starting_price: params[:starting_price].to_i,
                              buyout_price: params[:buyout_price].presence&.to_i)
    in [:ok, _]
      redirect_to auction_path(id), notice: "出品しました"
    in [:rejected, reason]
      redirect_to root_path, alert: helpers.rejection_message(reason)
    end
  end

  # 詳細はイベントそのものを見せる。?at=N なら N件目のイベント時点の状態を再生して表示
  def show
    @auction_id = params[:id]
    @events = StoredEvent.for_stream(Auction.stream_id(@auction_id)).to_a
    raise ActiveRecord::RecordNotFound if @events.empty?

    @states = Auction.history(@auction_id, @events.map(&:event))
    @at = params[:at]&.to_i&.clamp(1, @events.size)

    # 現在の状態はアクターに聞く（書き込み側の最新）。過去はイベントを再生した結果
    @state = @at ? @states[@at] : Auction.new(@auction_id).state
    @listing_version = StreamCheckpoint.find_by(stream_id: Auction.stream_id(@auction_id))&.version || 0
  end

  def close
    case Auction.new(params[:id]).close(current_user)
    in [:ok, _]
      redirect_to auction_path(params[:id]), notice: "出品を終了しました"
    in [:rejected, reason]
      redirect_to auction_path(params[:id]), alert: helpers.rejection_message(reason)
    end
  end
end
