class Api::CheckoutsController < Api::PublicController
  # Unauthenticated and hits Stripe on every call — cap per-IP.
  rate_limit to: 20, within: 1.minute, with: -> { head :too_many_requests }

  rescue_from Product::CheckoutNotConfigured, with: -> { head :service_unavailable }

  # price_id comes straight off a public URL, so a stale bookmark, a retired price,
  # or a crawler that lowercased the link (Stripe ids are case-sensitive) is a client
  # error, not a 500 that pages us. Genuinely broken config still raises
  # CheckoutNotConfigured above.
  rescue_from Stripe::InvalidRequestError, with: :price_not_found

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
    # A GET is a human who followed a buy link, so send them to the storefront's
    # pricing section rather than showing them JSON — a stale bookmark then still has
    # a chance of converting. checkout_cancel_url is already that page (it's where
    # Stripe returns someone who backs out), so there's nothing new to configure.
    # A POST is a client that wants the machine-readable error contract.
    def price_not_found
      cancel_url = Product.find_by(slug: params[:product_slug])&.checkout_cancel_url
      if request.get? && cancel_url.present?
        redirect_to cancel_url, status: :see_other, allow_other_host: true
      else
        render_api_error(:price_not_found)
      end
    end

    def checkout_session
      Product.find_by!(slug: params[:product_slug]).create_checkout_session(
        price_id: params.require(:price_id), email: params[:email],
        renew_license_key: params[:renew_license_key],
        client_reference_id: params[:client_reference_id], ref: params[:ref])
    end
end
