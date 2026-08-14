class CreatePurchases < ActiveRecord::Migration[8.1]
  # Keep this byte-identical to Purchase::NORMALIZED_EMAIL_SQL (and to
  # Purchase.normalize_email in Ruby). Postgres only uses the expression index when the
  # query's expression matches this one exactly; a drift costs a sequential scan, and a
  # drift against the Ruby mirror costs a customer their unlock.
  NORMALIZED_EMAIL = <<~SQL.squish
    CASE WHEN split_part(lower(btrim(email)), '@', 2) IN ('gmail.com','googlemail.com')
         THEN replace(split_part(split_part(lower(btrim(email)), '@', 1), '+', 1), '.', '')
         ELSE split_part(split_part(lower(btrim(email)), '@', 1), '+', 1)
    END || '@' || split_part(lower(btrim(email)), '@', 2)
  SQL

  def change
    # What the unlock flow entitles on: one row per order, keyed on the buyer's email
    # rather than an account, because there are no accounts. Nothing here is ever revoked
    # except by a refund, and a refunded row is kept (not deleted) so support can see it.
    create_table :purchases, id: :uuid do |t|
      t.references :product, null: false, foreign_key: true, type: :uuid
      # The address EXACTLY as the provider gave it — the one we mail codes to. Matching is
      # done through the normalized expression below, so nothing is lost to normalization.
      t.string :email, null: false
      t.string :tier, null: false             # standard (a year of updates) | forever
      t.datetime :purchased_at, null: false
      t.date :updates_until                   # nil = forever
      t.string :provider, null: false         # stripe | lemon_squeezy | polar
      t.string :provider_order_id, null: false
      t.datetime :refunded_at
      t.string :platforms, array: true, null: false, default: [ "mac", "windows", "iphone" ]
      t.timestamps
    end

    # The idempotency backbone: a redelivered webhook, or a re-run backfill, finds the row
    # instead of writing a second one.
    add_index :purchases, [ :provider, :provider_order_id ], unique: true

    # Ana.Perez+cozy@Gmail.com and anaperez@gmail.com are one inbox, so they must be one
    # customer at unlock time. Not unique — buying twice is allowed.
    add_index :purchases, "product_id, (#{NORMALIZED_EMAIL})",
      name: "index_purchases_on_product_and_normalized_email"
  end
end
