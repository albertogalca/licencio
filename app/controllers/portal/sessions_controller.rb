class Portal::SessionsController < Portal::BaseController
  skip_before_action :require_customer

  def create
    if token = PortalToken.authenticate(params[:token])
      reset_session
      session[:customer_id] = token.customer_id
      session[:portal_product_id] = token.product_id # product is bound to the token
      token.destroy! # single-use link
      redirect_to portal_root_path
    else
      redirect_to new_portal_recovery_path, alert: "That link is invalid or has expired. Request a new one."
    end
  end

  def destroy
    product = current_product
    reset_session
    redirect_to new_portal_recovery_path(product: product&.slug), notice: "Signed out."
  end
end
