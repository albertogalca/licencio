class Admin::RedemptionCodesController < Admin::BaseController
  def index
    @stats = RedemptionCode.pool_stats
    @products = Product.where(id: @stats.keys.map(&:first)).index_by(&:id)
    @codes = paginate(RedemptionCode.listed(q: params[:q], status: params[:status])
      .includes(:product, :customer, :license).order(updated_at: :desc))
  end

  def revoke
    code = RedemptionCode.find(params[:id])
    code.revoke!
    redirect_to admin_redemption_codes_path(q: params[:q].presence), notice: "Code …#{code.code_hint} revoked."
  end
end
