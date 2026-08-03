# Read-only "does this key entitle you?" for clients that can't hold the product API key —
# an App Store binary is unzippable, and that key mints licenses and trials. So: public,
# key in, entitlement out. No activation is created and no seat is consumed.
class Api::ValidationsController < Api::PublicController
  # Confirms whether a key exists, so it's the obvious thing to grind against. Same ceiling
  # as the recovery form. Scoped to :create so preflights don't spend the budget.
  rate_limit to: 5, within: 1.minute, only: :create, with: -> { head :too_many_requests }

  # The only endpoint a browser origin ever calls: an iOS WKWebView posts from
  # capacitor://localhost, and JSON isn't a CORS-safelisted content type, so it preflights.
  # Wildcard is honest here — public, read-only, rate limited, and no cookie or API key rides
  # along, so there's no credential for another origin to borrow.
  before_action :set_cors_headers

  def preflight
    head :no_content
  end

  def create
    product = Product.find_by!(slug: params[:product_slug])
    license = product.licenses.find_by!(license_key: params[:license_key].to_s.strip)

    if unlockable?(license)
      render json: { valid: true, tier: license.loops_tier,
                     expires_at: license.expires_at&.iso8601,
                     update_eligible: license.update_eligible? }
    else
      render_api_error(refusal_code(license))
    end
  end

  private
    def set_cors_headers
      headers["Access-Control-Allow-Origin"]  = "*"
      headers["Access-Control-Allow-Headers"] = "Content-Type"
      headers["Access-Control-Max-Age"]       = "86400"
    end

    # Deliberately looser than License#activatable?: a lapsed update window still owns the app,
    # so an expired annual license unlocks mobile and simply reports update_eligible: false.
    # A trial doesn't — seven days must not buy a permanent unlock.
    def unlockable?(license)
      !license.trial? && !license.refunded? && !license.inactive?
    end

    def refusal_code(license)
      return :license_not_eligible if license.trial? # a live license, just not one that unlocks
      license.refunded? ? :license_refunded : :license_inactive
    end
end
