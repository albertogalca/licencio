# The storefront's gift card page. Public and CORS-wildcard like the unlock endpoints: the code
# printed on the card is the credential, and nothing else rides along. What comes back is only
# what the card shows; the buyer's address never leaves this server.
class V1::GiftsController < Api::PublicController
  # Declared before the limiters, for the reason V1::UnlocksController gives.
  before_action :set_cors_headers

  # 60 bits of code against this budget is never guessed; the limit keeps a script honest.
  rate_limit to: 30, within: 1.minute, only: %i[show from_checkout], name: "read",
    with: -> { head :too_many_requests }
  # Every redemption sends mail to a caller-supplied address.
  rate_limit to: 10, within: 1.hour, only: :redeem, name: "redeem",
    with: -> { head :too_many_requests }

  def preflight
    head :no_content
  end

  def show
    gift = find_gift or return render_api_error(:gift_not_found)
    render json: gift.card
  end

  # Stripe returns the buyer here with the session id, sometimes a moment before the webhook
  # has made the gift. The page asks again until it is there, so a 404 means "not yet".
  def from_checkout
    product = find_product or return render_api_error(:product_not_found)
    gift = product.gifts.find_by(stripe_session_id: params[:session_id].to_s) or return render_api_error(:gift_not_found)
    render json: gift.card
  end

  def redeem
    gift = find_gift or return render_api_error(:gift_not_found)
    email = params[:email].to_s.strip
    return render_api_error(:invalid_email) unless email.match?(EMAIL_SHAPE)

    gift.redeem!(email:)
    render json: { ok: true, email: }
  rescue Gift::Unavailable => error
    render_api_error(:"gift_#{error.state}")
  end

  private
    def find_product = Product.find_by(slug: params[:product_slug])

    def find_gift = find_product&.gifts&.find_by_code(params[:code])

    def set_cors_headers
      headers["Access-Control-Allow-Origin"]  = "*"
      headers["Access-Control-Allow-Headers"] = "Content-Type"
      headers["Access-Control-Max-Age"]       = "86400"
    end
end
