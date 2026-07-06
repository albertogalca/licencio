class Webhooks::StripeController < ActionController::API
  def create
    event = Stripe::Webhook.construct_event(
      request.body.read, request.headers["Stripe-Signature"], ENV["STRIPE_WEBHOOK_SECRET"])
    if event.type == "checkout.session.completed"
      session = event.data.object
      customer = Customer.upsert_from_stripe(
        email: session.customer_details.email, stripe_customer_id: session.customer)
      License.fulfill!(
        product: Product.find(session.metadata.licencio_product_id), customer:,
        quantity: session.metadata.quantity.to_i,
        stripe_payment_id: session.payment_intent || session.id,
        renew_key: session.metadata[:renew_license_key]) # [] -> nil when absent (method access would raise)
    end
    head :ok
  rescue Stripe::SignatureVerificationError
    head :bad_request
  end
end
