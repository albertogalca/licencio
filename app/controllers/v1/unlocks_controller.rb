# Unlock by email, with no account behind it. Type an address, get six digits in the inbox,
# type them back, and the app is permanently unlocked with a signed entitlement token. No
# password, no session, no device limit, nothing to revoke — the token is verified offline
# by the client, forever, against a public key it ships with.
#
# The license-key system next door is untouched: this is an additional way in for the
# products that sell through `purchases`, not a replacement.
class V1::UnlocksController < Api::PublicController
  # Anything at all about an address — that it bought, that it didn't, how long a lookup
  # took — is a leak. So /request always answers the same {ok: true} at the same speed, and
  # the purchase check happens in the job where no caller can time it.
  #
  # Per-address budget, distinct from the per-IP rate limits below: without it a botnet
  # could bury one inbox from a thousand addresses.
  MAX_CODES_PER_WINDOW = 3
  CODE_REQUEST_WINDOW = 15.minutes

  # Deliberately weak — this only has to catch a typo or a bot's garbage, never to judge
  # whether an inbox exists. A wrong-but-plausible address simply gets no email.
  EMAIL_SHAPE = /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/

  # Sends mail to a caller-supplied address, so it's throttled per-IP too. The only place
  # this endpoint looks at an IP at all — nothing about the caller is logged or stored.
  rate_limit to: 10, within: 1.hour, only: :request_code, with: -> { head :too_many_requests }
  # Guessing budget belongs to the code (LoginCode::MAX_ATTEMPTS); this just stops one host
  # from grinding many codes at once.
  rate_limit to: 10, within: 1.minute, only: :verify, with: -> { head :too_many_requests }

  # Cozy for iPhone posts from capacitor://localhost and the marketing site from the web, so
  # both preflight. Wildcard is honest: public, rate limited, and no cookie or API key rides
  # along, so there's no credential for another origin to borrow.
  before_action :set_cors_headers

  def preflight
    head :no_content
  end

  def request_code
    product = Product.find_by(slug: params[:product_slug]) or return render_api_error(:product_not_found)
    email = params[:email].to_s.strip
    return render_api_error(:invalid_email) unless email.match?(EMAIL_SHAPE)

    # Over budget: still {ok: true}, still no hint. The caller cannot tell a throttled
    # address from a stranger's from a buyer's.
    UnlockCodeJob.perform_later(product, email) unless over_code_budget?(product, email)
    render json: { ok: true }
  end

  def verify
    product = Product.find_by(slug: params[:product_slug]) or return render_api_error(:product_not_found)
    code = newest_live_code(product, params[:email])
    return refuse(:code_invalid, product) if code.nil?

    result = code.verify!(params[:code].to_s.strip)
    return refuse(result, product) unless result == :ok

    purchase = Purchase.for_email(product, params[:email]).live.order(:purchased_at).last
    return refuse(refusal_without_purchase(product), product) if purchase.nil?

    # device_id rides into the token and nowhere else — no table records which machines a
    # customer unlocked on, because unlimited devices means there is nothing to count.
    render json: {
      ok: true,
      token: product.sign_unlock_token(purchase.token_claims(device_id: params[:device_id].to_s)),
      tier: purchase.tier,
      updates_until: purchase.updates_until&.iso8601,
      platforms: purchase.platforms
    }
  end

  private
    def set_cors_headers
      headers["Access-Control-Allow-Origin"]  = "*"
      headers["Access-Control-Allow-Headers"] = "Content-Type"
      headers["Access-Control-Max-Age"]       = "86400"
    end

    def newest_live_code(product, raw_email)
      product.login_codes
        .where(email: Purchase.normalize_email(raw_email), consumed_at: nil)
        .order(:created_at).last
    end

    # A code that verified but has no live purchase behind it: say which, because "refunded"
    # and "we've never seen this address" need different answers from support, and the
    # person holding the code has already proved they own the inbox.
    def refusal_without_purchase(product)
      Purchase.for_email(product, params[:email]).exists? ? :purchase_refunded : :purchase_not_found
    end

    # Counted on the normalized address, so +tags don't multiply the budget. A cache that
    # can't count (the null store in test) simply doesn't throttle.
    def over_code_budget?(product, email)
      key = "unlock_req:#{product.id}:#{Purchase.normalize_email(email)}"
      count = Rails.cache.increment(key, 1, expires_in: CODE_REQUEST_WINDOW)
      count.present? && count > MAX_CODES_PER_WINDOW
    end

    # Enough to spot an attack or a broken client, and nothing that identifies a person:
    # no address, no IP. The failures worth counting are code_invalid and too_many_attempts.
    def refuse(code, product)
      Rails.logger.info("unlock.verify_failed code=#{code} product=#{product.slug}")
      render_api_error(code)
    end
end
