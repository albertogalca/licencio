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
    when "checkout.session.completed", "checkout.session.async_payment_succeeded"
      session = event.data.object
      # A delayed payment method (bank debit, voucher, buy-now-pay-later) completes the session
      # while payment_status is still "unpaid" and settles days later, so completion alone is not
      # proof of payment — fulfilling on it hands out a license for money that can still fail to
      # arrive. Stripe re-delivers as async_payment_succeeded once it does, which is why that
      # event fulfills through the same branch. async_payment_failed needs no handler: nothing
      # was minted, so there is nothing to revoke.
      return head :ok unless session.payment_status.to_s.in?(%w[paid no_payment_required])
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
    when "charge.dispute.created"
      # A chargeback is a refund the buyer took rather than asked for: Stripe withholds the
      # money the moment the dispute opens. Treated identically, which also drops the sale out
      # of Payment#payable, so the affiliate commission stops being owed on money we no longer
      # have. ponytail: no restore path for a dispute we later win — rare enough on a $39 Mac
      # app to fix by hand; handle charge.dispute.closed if that stops being true.
      License.refund!(product:, stripe_payment_intent: event.data.object.payment_intent)
      Purchase.refund!(product:, provider_order_id: event.data.object.payment_intent)
    end
    head :ok
  rescue Stripe::SignatureVerificationError
    head :bad_request
  end

  private
    def find_product = Product.find_by(id: params[:product_id])
end
