class Portal::BaseController < ApplicationController
  layout "portal"

  before_action :require_customer

  helper_method :current_customer, :current_product

  private
    def current_customer
      @current_customer ||= Customer.find_by(id: session[:customer_id])
    end

    # The portal is scoped to the product from the magic link — a Cozy session never shows Picmal.
    def current_product
      @current_product ||= Product.find_by(id: session[:portal_product_id])
    end

    def require_customer
      redirect_to new_portal_recovery_path(product: params[:product]) unless current_customer && current_product
    end
end
