class Admin::PayoutsController < Admin::BaseController
  def create
    affiliate = Affiliate.find(params[:affiliate_id])
    payout = affiliate.payouts.new(payout_params)
    payout.paid_at ||= Time.current
    if payout.save
      redirect_to admin_affiliate_path(affiliate), notice: "Payout recorded."
    else
      redirect_to admin_affiliate_path(affiliate), alert: payout.errors.full_messages.to_sentence
    end
  end

  private
    def payout_params
      params.require(:payout).permit(:amount_cents, :currency, :note)
    end
end
