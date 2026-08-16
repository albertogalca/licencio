class Portal::RenewalsController < Portal::BaseController
  # Public, like recoveries: a renewal link has to survive a reminder email read three days
  # later, long after the 30-minute magic-link token died. The license key is its own secret,
  # and the only thing anyone can do with someone else's is pay to extend it.
  skip_before_action :require_customer

  ATTRIBUTION_PARAMS = %i[client_reference_id ref affonso_referral].freeze

  # Hits Stripe, and `new` confirms whether a key exists — cap per-IP to blunt key probing.
  rate_limit to: 5, within: 1.minute,
    with: -> { redirect_to new_portal_renewal_path, alert: "Too many requests. Try again in a minute." }

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

  private
    # The storefront hangs these on the renew link, `new` carries them across the form as
    # hidden fields, and they end up in the Checkout Session the same way /api/checkout's do.
    # Anything long enough to make Stripe reject the whole session is dropped rather than
    # allowed to turn a junk query param into a failed renewal — losing the attribution on
    # one renewal beats losing the renewal.
    def attribution
      ATTRIBUTION_PARAMS.index_with { |key| params[key].presence&.then { |v| v if v.length <= 200 } }
    end
end
