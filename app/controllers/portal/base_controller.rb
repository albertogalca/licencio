class Portal::BaseController < ApplicationController
  layout "portal"

  before_action :require_customer

  helper_method :current_customer

  private
    def current_customer
      @current_customer ||= Customer.find_by(id: session[:customer_id])
    end

    def require_customer
      redirect_to new_portal_recovery_path unless current_customer
    end
end
