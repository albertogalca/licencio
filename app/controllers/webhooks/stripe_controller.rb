class Webhooks::StripeController < ActionController::API
  def create
    product = Product.find(params[:product_id])
    event = product.verify_webhook(request.body.read, request.headers["Stripe-Signature"])
    case event.type
    when "checkout.session.completed"
      License.fulfill_from_stripe_session(event.data.object)
    when "charge.refunded"
      License.refund!(stripe_payment_id: event.data.object.payment_intent)
    end
    head :ok
  rescue Stripe::SignatureVerificationError
    head :bad_request
  end
end
