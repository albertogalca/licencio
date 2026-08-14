class Webhooks::StripeController < ActionController::API
  def create
    # Only the product lookup should 404 — a RecordNotFound raised *inside*
    # fulfillment must surface as a 500 so Stripe retries a real failure rather
    # than treating it as a permanently-unknown endpoint.
    product = find_product or return head :not_found
    event = product.verify_webhook(request.body.read, request.headers["Stripe-Signature"])
    # Actions are scoped to THIS endpoint's product: a signed event for one product's
    # secret can only mint/revoke that product's licenses, never another's.
    case event.type
    when "checkout.session.completed"
      session = event.data.object
      License.fulfill_from_stripe_session(product, session)
      # The unlock flow is opted into per price, by a `tier` in its metadata, and lives
      # alongside the license it just minted — the same sale grants both. A price with no
      # tier (picmal's) records nothing.
      Purchase.record_stripe!(product, session, price: product.session_price(session))
    when "charge.refunded"
      charge = event.data.object
      # Full refunds only revoke the license; partial refunds — and uncaptured charges, where
      # both amounts are 0 — leave it active.
      if charge.amount_captured.to_i.positive? && charge.amount_refunded == charge.amount_captured
        License.refund!(product:, stripe_payment_intent: charge.payment_intent)
        Purchase.refund!(product:, provider_order_id: charge.payment_intent)
      end
    end
    head :ok
  rescue Stripe::SignatureVerificationError
    head :bad_request
  end

  private
    def find_product = Product.find_by(id: params[:product_id])
end
