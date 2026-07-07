class Webhooks::StripeController < ActionController::API
  def create
    # Only the product lookup should 404 — a RecordNotFound raised *inside*
    # fulfillment must surface as a 500 so Stripe retries a real failure rather
    # than treating it as a permanently-unknown endpoint.
    product = find_product or return head :not_found
    event = product.verify_webhook(request.body.read, request.headers["Stripe-Signature"])
    case event.type
    when "checkout.session.completed"
      License.fulfill_from_stripe_session(event.data.object)
    when "charge.refunded"
      charge = event.data.object
      # Full refunds only revoke the license; partial refunds leave it active.
      License.refund!(stripe_payment_id: charge.payment_intent) if charge.amount_refunded == charge.amount
    end
    head :ok
  rescue Stripe::SignatureVerificationError
    head :bad_request
  end

  private
    def find_product = Product.find_by(id: params[:product_id])
end
