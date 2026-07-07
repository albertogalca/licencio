class Portal::SessionsController < Portal::BaseController
  skip_before_action :require_customer

  def create
    if token = PortalToken.authenticate(params[:token])
      reset_session
      session[:customer_id] = token.customer_id
      session[:portal_product_id] = token.product_id # product is bound to the token
      # Link is reusable within its 30-minute window (see PortalToken) — reopening it isn't confusing,
      # and it survives mail-scanner / browser prefetches that a one-shot token wouldn't.
      redirect_to portal_root_path
    else
      # Carry the product from the link so an expired link recovers to the right product.
      redirect_to new_portal_recovery_path(product: params[:product]), alert: "That link is invalid or has expired. Request a new one."
    end
  end

  def destroy
    product = current_product
    reset_session
    redirect_to new_portal_recovery_path(product: product&.slug), notice: "Signed out."
  end
end
