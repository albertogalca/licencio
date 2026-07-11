class Admin::AffiliatesController < Admin::BaseController
  before_action :set_affiliate, only: [ :show, :edit, :update ]

  def index
    scope = Affiliate.order(:code)
    scope = scope.where("code ILIKE :p OR name ILIKE :p OR email ILIKE :p", p: "%#{params[:q].strip}%") if params[:q].present?
    scope = scope.where(status: params[:status]) if params[:status].present?
    @affiliates = paginate(scope)
    # Two grouped queries feed the whole page — no per-row lookups.
    @sales    = Payment.commissionable.group(:affiliate_id).count
    @earned   = Payment.commissionable.group(:affiliate_id).sum(:commission_cents)
  end

  def show
    @payments = @affiliate.payments.includes(license: :product).order(created_at: :desc)
    @payouts  = @affiliate.payouts.order(paid_at: :desc)
    @payable_cents = @affiliate.payments.payable.sum(:commission_cents)
    @paid_cents    = @affiliate.payouts.sum(:amount_cents)
    @owed_cents    = @payable_cents - @paid_cents
  end

  def edit
  end

  def update
    if @affiliate.update(affiliate_params)
      redirect_to admin_affiliate_path(@affiliate), notice: "Affiliate updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private
    def set_affiliate
      @affiliate = Affiliate.find(params[:id])
    end

    def affiliate_params
      params.require(:affiliate).permit(:name, :email, :code, :payout_email, :commission_percent, :status)
    end
end
