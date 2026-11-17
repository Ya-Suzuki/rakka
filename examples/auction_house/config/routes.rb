Rails.application.routes.draw do
  root "auctions#index"

  resources :auctions, only: %i[index create show] do
    post :close, on: :member
    resources :bids, only: :create
  end
  resource :session, only: :update

  get "up" => "rails/health#show", as: :rails_health_check
end
