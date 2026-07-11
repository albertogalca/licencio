class Affiliate::SessionsController < Affiliate::BaseController
  skip_before_action :require_affiliate

  def create
    if token = AffiliateToken.authenticate(params[:token])
      reset_session
      session[:affiliate_id] = token.affiliate_id # affiliate is read off the token, never params
      redirect_to affiliate_root_path
    else
      redirect_to new_affiliate_recovery_path, alert: "That link is invalid or has expired. Request a new one."
    end
  end

  def destroy
    reset_session
    redirect_to new_affiliate_recovery_path, notice: "Signed out."
  end
end
