class SessionsController < ApplicationController
  def update
    name = params[:name].to_s.strip
    session[:user] = name if name.present?
    redirect_back fallback_location: root_path
  end
end
