class Api::CheckoutsController < Api::PublicController
  # Unauthenticated and hits Stripe on every call — cap per-IP.
  rate_limit to: 20, within: 1.minute, with: -> { head :too_many_requests }

  rescue_from Product::CheckoutNotConfigured, with: -> { head :service_unavailable }

  # price_id comes straight off a public URL, so a stale bookmark, a retired price,
  # or a crawler that lowercased the link (Stripe ids are case-sensitive) is a client
  # error, not a 500 that pages us. Genuinely broken config still raises
  # CheckoutNotConfigured above.
  rescue_from Stripe::InvalidRequestError, with: :price_not_found

  # Every GET here spends a Stripe Checkout Session, and the buy link is a bare
  # <a href> that crawlers and link previews follow too. In the week of 21 Sep 2026,
  # 92 of Cozy's 131 sessions arrived without the visitor id a real click carries.
  # Those requests go to the pricing page and never reach Stripe. Only explicit bot
  # tokens match: a false match would turn a buyer away.
  #
  # Two more came through in the week of 28 Sep 2026, both seen in the request log.
  # "iPhone OS 13_2_3 ... Version/13.0" is a fixed fake user agent sent from Tencent
  # Cloud addresses, never a real phone in 2026. And a scraper on rotating residential
  # IPs fetches the buy links daily with a browser user agent, but with the query
  # sorted (price_id before product_slug) and with prices retired months ago. Every
  # storefront writes product_slug first, so that order never comes from a real click.
  BOT_USER_AGENT = /bot|crawl|spider|slurp|facebookexternalhit|embedly|headless|python-requests|curl|wget|go-http-client|axios|node-fetch|scrapy|okhttp|iPhone OS 13_2_3 /i

  before_action :keep_bots_out_of_stripe, only: :new

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
    # A HEAD probe or a bot gets the same answer a lost buyer gets: the pricing page.
    def keep_bots_out_of_stripe
      return unless request.head? || request.user_agent.blank? || request.user_agent.match?(BOT_USER_AGENT) ||
        request.query_string.start_with?("price_id=")

      cancel_url = Product.find_by(slug: params[:product_slug])&.checkout_cancel_url
      if cancel_url.present?
        redirect_to cancel_url, status: :see_other, allow_other_host: true
      else
        head :no_content
      end
    end

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
        upgrade_license_key: params[:upgrade_license_key],
        client_reference_id: params[:client_reference_id],
        affonso_referral: params[:affonso_referral])
    end
end
