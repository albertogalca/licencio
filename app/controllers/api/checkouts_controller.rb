class Api::CheckoutsController < Api::PublicController
  # Unauthenticated and hits Stripe on every call — cap per-IP.
  rate_limit to: 20, within: 1.minute, with: -> { head :too_many_requests }

  def create
    product = Product.find_by!(slug: params[:product_slug])
    session = product.create_checkout_session(
      price_id: params.require(:price_id),
      email: params[:email], renew_license_key: params[:renew_license_key])
    render json: { url: session.url }
  end
end
