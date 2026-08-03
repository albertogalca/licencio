# Read-only "does this key entitle you?" for clients that can't hold the product API key —
# an App Store binary is unzippable, and that key mints licenses and trials. So: public,
# key in, entitlement out. No activation is created and no seat is consumed.
class Api::ValidationsController < Api::PublicController
  # Confirms whether a key exists, so it's the obvious thing to grind against. Same ceiling
  # as the recovery form.
  rate_limit to: 5, within: 1.minute, with: -> { head :too_many_requests }

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
