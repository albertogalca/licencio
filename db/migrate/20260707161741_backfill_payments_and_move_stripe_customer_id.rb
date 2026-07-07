class BackfillPaymentsAndMoveStripeCustomerId < ActiveRecord::Migration[8.1]
  # Data migration: seed the new payments/license columns from existing data, THEN drop the
  # misplaced customers.stripe_customer_id. Raw SQL so it doesn't depend on model code.
  def up
    # Move the (per-product) Stripe customer id onto each license before the column disappears.
    execute <<~SQL
      UPDATE licenses
      SET stripe_customer_id = customers.stripe_customer_id
      FROM customers
      WHERE licenses.customer_id = customers.id
        AND customers.stripe_customer_id IS NOT NULL
    SQL

    # One purchase Payment per license that already carries a Stripe payment intent.
    # Imported (LS/Polar) licenses have none — they get no payment row, as intended.
    execute <<~SQL
      INSERT INTO payments (id, license_id, stripe_payment_intent, kind, created_at, updated_at)
      SELECT gen_random_uuid(), id, stripe_payment_id, 'purchase', now(), now()
      FROM licenses
      WHERE stripe_payment_id IS NOT NULL
    SQL

    remove_index :customers, :stripe_customer_id, unique: true
    remove_column :customers, :stripe_customer_id
  end

  def down
    add_column :customers, :stripe_customer_id, :string
    add_index :customers, :stripe_customer_id, unique: true
    execute <<~SQL
      UPDATE customers
      SET stripe_customer_id = sub.stripe_customer_id
      FROM (
        SELECT DISTINCT ON (customer_id) customer_id, stripe_customer_id
        FROM licenses
        WHERE stripe_customer_id IS NOT NULL AND customer_id IS NOT NULL
        ORDER BY customer_id, created_at DESC
      ) sub
      WHERE customers.id = sub.customer_id
    SQL
  end
end
