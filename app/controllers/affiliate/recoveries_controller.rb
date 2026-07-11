class Affiliate::RecoveriesController < Affiliate::BaseController
  skip_before_action :require_affiliate

  # Sends email — throttle per-IP to blunt address enumeration and mail bombing.
  rate_limit to: 5, within: 1.minute, only: :create,
    with: -> { redirect_to new_affiliate_recovery_path, alert: "Too many requests. Try again in a minute." }

  def new
  end

  def create
    ::Affiliate.find_by(email: params[:email].to_s.downcase.strip)&.send_dashboard_access_later
    redirect_to new_affiliate_recovery_path, notice: "If that email is an approved affiliate, a sign-in link is on its way."
  end
end
