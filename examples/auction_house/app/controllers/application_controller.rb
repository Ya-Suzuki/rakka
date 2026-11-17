class ApplicationController < ActionController::Base
  allow_browser versions: :modern

  helper_method :current_user

  # Rakkaの実行時エラー（メールボックス満杯、シャード停止、集約の例外など）
  rescue_from Rakka::Error do |error|
    redirect_back fallback_location: root_path,
                  alert: "処理できませんでした（#{error.class.name.demodulize}）。少し待ってからもう一度試してください"
  end

  private

  # ログインの代わりに、名前をセッションに持つだけ
  def current_user
    session[:user] ||= "guest-#{SecureRandom.alphanumeric(4).downcase}"
  end
end
