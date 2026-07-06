class Webhooks::StripeController < ActionController::API
  def create
    event = Stripe::Webhook.construct_event(
      request.body.read, request.headers["Stripe-Signature"], ENV["STRIPE_WEBHOOK_SECRET"])
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
