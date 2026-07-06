class AddUniqueIndexOnLicenseStripePaymentId < ActiveRecord::Migration[8.1]
  def change
    # Idempotency backstop for concurrent Stripe webhook retries — the app-level exists? check races.
    # Partial so imported/trial licenses (null payment id) don't collide.
    add_index :licenses, [ :product_id, :stripe_payment_id ], unique: true,
      where: "stripe_payment_id IS NOT NULL", name: "index_licenses_on_product_and_stripe_payment"
  end
end
