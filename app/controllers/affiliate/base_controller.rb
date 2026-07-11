class Affiliate::BaseController < ApplicationController
  layout "portal"

  before_action :require_affiliate

  helper_method :current_affiliate

  private
    def current_affiliate
      @current_affiliate ||= ::Affiliate.approved.find_by(id: session[:affiliate_id])
    end

    def require_affiliate
      redirect_to new_affiliate_recovery_path unless current_affiliate
    end
end
