class Api::CheckoutsController < Api::PublicController
  # Unauthenticated and hits Stripe on every call — cap per-IP.
  rate_limit to: 20, within: 1.minute, with: -> { head :too_many_requests }

  rescue_from Product::CheckoutNotConfigured, with: -> { head :service_unavailable }

  # GET — a storefront buy button lands here and is 302'd straight to Stripe
  # Checkout. Keeps the marketing site a plain static page (a bare <a href>, no
  # CORS, no JS) while the session (seats/metadata/success URLs) is built here.
  def new
    redirect_to checkout_session.url, status: :see_other, allow_other_host: true
  end

  # POST — same session as JSON { url } for JS/desktop clients.
  def create
    render json: { url: checkout_session.url }
  end

  private
    def checkout_session
      Product.find_by!(slug: params[:product_slug]).create_checkout_session(
        price_id: params.require(:price_id), email: params[:email],
        renew_license_key: params[:renew_license_key],
        client_reference_id: params[:client_reference_id], ref: params[:ref])
    end
end
