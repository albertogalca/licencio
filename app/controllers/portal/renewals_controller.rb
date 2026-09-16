class Portal::RenewalsController < Portal::BaseController
  # Public, like recoveries: a renewal link has to survive a reminder email read three days
  # later, long after the 30-minute magic-link token died. The license key is its own secret,
  # and the only thing anyone can do with someone else's is pay to extend it.
  skip_before_action :require_customer

  # Hits Stripe, and `new` confirms whether a key exists — cap per-IP to blunt key probing.
  # Render, don't redirect: the redirect target is this same limited controller, so under the
  # cap every redirect re-counts and Chrome dies on ERR_TOO_MANY_REDIRECTS.
  rate_limit to: 10, within: 1.minute,
    with: -> { render plain: "Too many requests. Wait a minute, then reload.", status: :too_many_requests }

  def new
    @license = License.find_by_key(params[:license_key].to_s.strip)
    # Brands the layout. The storefront link carries ?product=<slug> so the page is branded
    # before a key is typed, same as upgrades; a found license always wins.
    @product = @license&.product || (Product.matching(params[:product]).first if params[:product].present?)
    @options = @license&.renewal_options || []
  end

  def create
    license = License.find_by_key(params[:license_key].to_s.strip)
    if license
      # `kind` names one of the license's own options; renewal_checkout refuses anything else,
      # and a form that never posted one still means "another year" as it always did.
      redirect_to license.renewal_checkout(kind: params[:kind], **attribution).url,
        allow_other_host: true, status: :see_other
    else
      redirect_to new_portal_renewal_path(license_key: params[:license_key]),
        alert: "We couldn't find that license key."
    end
  rescue ActiveRecord::RecordNotFound
    # An option this license doesn't have — a stale form or a forged `kind`, not an outage, so
    # "try again" would be the wrong advice.
    redirect_to new_portal_renewal_path(license_key: params[:license_key]),
      alert: "Renewal isn't available for that license."
  rescue Product::CheckoutNotConfigured, Stripe::StripeError
    redirect_to new_portal_renewal_path(license_key: params[:license_key]),
      alert: "Renewal is temporarily unavailable — please try again."
  end
end
