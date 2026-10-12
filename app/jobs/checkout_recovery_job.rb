class CheckoutRecoveryJob < ApplicationJob
  def perform(product, email:, recovery_url:, expires_at: nil)
    return if product.nil? || !product.checkout_recovery?
    return if expires_at&.past?
    # Somebody who gave up on one session and paid through another already has what the
    # email would sell them.
    return if product.licenses.joins(:customer).where("lower(customers.email) = ?", email.downcase).exists?

    customer = Customer.upsert!(email:)

    # One per address per product, ever. Consent to promotions is not consent to a reminder
    # every time somebody opens checkout and walks away.
    Notification.once(customer:, kind: "checkout_recovery", reference_id: product.slug) do
      Loops.send_transactional(
        api_key: product.loops_api_key_or_default,
        transactional_id: product.checkout_recovery_transactional_id,
        email:,
        data: {
          recovery_url:,
          product_name: product.name,
          sender_email: product.sender_email,
          pricing_url: product.checkout_cancel_url
        }
      )
    end
  end
end
