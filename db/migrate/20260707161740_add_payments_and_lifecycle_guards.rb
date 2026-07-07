class AddPaymentsAndLifecycleGuards < ActiveRecord::Migration[8.1]
  def change
    # Full Stripe payment history per license: idempotency backbone for fulfillment/renewal
    # and the map from a refunded payment_intent back to its license (survives renewals,
    # which overwrite licenses.stripe_payment_id with the latest intent).
    create_table :payments, id: :uuid do |t|
      t.references :license, type: :uuid, null: false, foreign_key: true
      t.string :stripe_payment_intent, null: false
      t.string :kind, null: false # purchase | renewal
      t.integer :amount_cents
      t.string :currency
      t.timestamps
      t.index :stripe_payment_intent, unique: true
    end

    # One-shot lifecycle-email dedup: a re-enqueue (or an already-succeeded retry) doesn't re-send.
    create_table :notifications, id: :uuid do |t|
      t.references :customer, type: :uuid, null: false, foreign_key: true
      t.string :kind, null: false # purchase | refund | expiry | portal
      t.string :reference_id, null: false # the license/token id the email concerns
      t.datetime :sent_at
      t.timestamps
      t.index [ :customer_id, :kind, :reference_id ], unique: true, name: "index_notifications_dedup"
    end

    # H2: the price a license was bought at, so renewal reuses it instead of a client-chosen one.
    add_column :licenses, :stripe_price_id, :string
    # M3: Stripe customer id belongs per-license (per-product Stripe accounts), not on the shared customer.
    add_column :licenses, :stripe_customer_id, :string
    # L3: so expiry reminders don't double-send on retry or drop a cohort on a missed run.
    add_column :licenses, :reminded_at, :datetime
  end
end
