class Admin::ApprovalsController < Admin::BaseController
  def create
    affiliate = Affiliate.find(params[:affiliate_id])
    affiliate.approve! # flips status + emails the magic-link dashboard URL
    redirect_to admin_affiliate_path(affiliate), notice: "Affiliate approved — sign-in link sent."
  end
end
