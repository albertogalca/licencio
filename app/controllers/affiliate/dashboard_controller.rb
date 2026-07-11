class Affiliate::DashboardController < Affiliate::BaseController
  def show
    @affiliate = current_affiliate
    payments = @affiliate.payments
    @sales_count   = payments.count
    @revenue_cents = payments.sum(:amount_cents)
    @payable_cents = payments.payable.sum(:commission_cents)
    @paid_cents    = @affiliate.payouts.sum(:amount_cents)
    @owed_cents    = @payable_cents - @paid_cents             # cleared the hold, minus what's paid
    # Commission still inside the 30-day hold and NOT refunded — i.e. genuinely still coming.
    # (A refunded sale drops out of both payable and pending; it never pays out.)
    @pending_cents = payments.commissionable.where(created_at: 30.days.ago..)
                       .joins(:license).where.not(licenses: { status: "refunded" }).sum(:commission_cents)
    @payouts  = @affiliate.payouts.order(paid_at: :desc)
    @products = Product.where.not(affiliate_landing_url: nil).order(:name) # products with a suggested link
  end
end
