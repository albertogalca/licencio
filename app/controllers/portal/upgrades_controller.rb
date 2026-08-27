class Portal::UpgradesController < Portal::BaseController
  # Public, like renewals: the storefront FAQ links straight here, and the license key is its
  # own secret. The only thing anyone can do with someone else's key is pay to add seats to it.
  skip_before_action :require_customer

  # Hits Stripe, and `new` confirms whether a key exists — cap per-IP to blunt key probing.
  # Render, don't redirect: the redirect target is this same limited controller, so under the
  # cap every redirect re-counts and Chrome dies on ERR_TOO_MANY_REDIRECTS.
  rate_limit to: 10, within: 1.minute,
    with: -> { render plain: "Too many requests. Wait a minute, then reload.", status: :too_many_requests }

  def new
    @license = License.find_by_key(params[:license_key].to_s.strip)
    # Brands the layout. The storefront link carries ?product=<slug> so the page is branded
    # before a key is typed, same as recoveries; a found license always wins.
    @product = @license&.product || (Product.matching(params[:product]).first if params[:product].present?)
    @options = @license&.upgrade_options || []
  end

  def create
    # Two-step on purpose. A bare key submit (no price picked yet) bounces back to `new`, which
    # renders the license's options with seat counts and prices — nobody lands on Stripe without
    # having SEEN what they're buying, even when there's only one option.
    if params[:price_id].blank?
      return redirect_to new_portal_upgrade_path(license_key: params[:license_key],
        product: params[:product].presence, **attribution.compact)
    end
    license = License.find_by_key(params[:license_key].to_s.strip)
    # The client picks WHICH of its own upgrades (a 1-seat license has two targets), but
    # upgrade_checkout only accepts a price from the license's own upgrade_options.
    if license
      redirect_to license.upgrade_checkout(price_id: params[:price_id], **attribution).url,
        allow_other_host: true, status: :see_other
    else
      redirect_to new_portal_upgrade_path(license_key: params[:license_key], product: params[:product].presence),
        alert: "We couldn't find that license key."
    end
  rescue ActiveRecord::RecordNotFound
    # upgrade_checkout raises this for a price outside the license's own options — a forged
    # price_id, not an outage, so "try again" would be the wrong advice.
    redirect_to new_portal_upgrade_path(license_key: params[:license_key], product: params[:product].presence),
      alert: "An upgrade isn't available for that license."
  rescue Product::CheckoutNotConfigured, Stripe::StripeError
    redirect_to new_portal_upgrade_path(license_key: params[:license_key], product: params[:product].presence),
      alert: "Upgrades are temporarily unavailable — please try again."
  end
end
