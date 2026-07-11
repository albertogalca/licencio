class Affiliate::SignupsController < Affiliate::BaseController
  skip_before_action :require_affiliate

  # Public form — throttle per-IP to blunt spam signups.
  rate_limit to: 5, within: 1.minute, only: :create,
    with: -> { redirect_to new_affiliate_signup_path, alert: "Too many requests. Try again in a minute." }

  def new
    @affiliate = ::Affiliate.new
  end

  # Creates a pending affiliate and sends NOTHING — approval in admin mints the code's magic link.
  # Invalid input (taken/malformed code, missing name) re-renders with errors so a real applicant
  # can fix it, rather than getting a false "thanks" and vanishing.
  def create
    @affiliate = ::Affiliate.new(affiliate_params.merge(status: "pending"))
    if @affiliate.save
      redirect_to new_affiliate_signup_path, notice: "Thanks! We'll review your application and email you if you're approved."
    else
      render :new, status: :unprocessable_entity
    end
  end

  private
    def affiliate_params
      params.require(:affiliate).permit(:name, :email, :code, :payout_email)
    end
end
