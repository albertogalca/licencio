# Cozy for iPhone posts its StoreKit 2 transaction here with an address, and the address
# gets the desktop license that purchase includes. Public, like the unlock endpoints: the
# signed transaction is the credential.
class V1::IapClaimsController < Api::PublicController
  # Same reasoning as V1::UnlocksController: the app posts from capacitor://localhost, and
  # the CORS headers go first so a throttled reply still reaches it.
  before_action :set_cors_headers

  # Every claim can send mail, to a new address or again to the first one.
  rate_limit to: 10, within: 1.hour, only: :create, with: -> { head :too_many_requests }

  def preflight
    head :no_content
  end

  def create
    product = Product.find_by(slug: params[:product_slug]) or return render_api_error(:product_not_found)
    email = params[:email].to_s.strip
    return render_api_error(:invalid_email) unless email.match?(EMAIL_SHAPE)

    License.claim_from_app_store!(product, AppStoreTransaction.verify(params[:jws]), email:)
    render json: { ok: true }
  rescue AppStoreTransaction::Invalid => error
    Rails.logger.info("iap.claim_refused reason=#{error.message} product=#{product.slug}")
    render_api_error(:transaction_invalid)
  end

  private
    def set_cors_headers
      headers["Access-Control-Allow-Origin"]  = "*"
      headers["Access-Control-Allow-Headers"] = "Content-Type"
      headers["Access-Control-Max-Age"]       = "86400"
    end
end
