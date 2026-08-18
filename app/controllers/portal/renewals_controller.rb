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
    @product = @license&.product # brands the layout
  end

  def create
    license = License.find_by_key(params[:license_key].to_s.strip)
    if license&.renewable? && license.renewal_price_id
      redirect_to license.renewal_checkout(**attribution).url, allow_other_host: true, status: :see_other
    else
      redirect_to new_portal_renewal_path(license_key: params[:license_key]),
        alert: "Renewal isn't available for that license."
    end
  rescue Product::CheckoutNotConfigured, ActiveRecord::RecordNotFound, Stripe::StripeError
    redirect_to new_portal_renewal_path(license_key: params[:license_key]),
      alert: "Renewal is temporarily unavailable — please try again."
  end
end
