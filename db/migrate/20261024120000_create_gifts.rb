class CreateGifts < ActiveRecord::Migration[8.1]
  def change
    create_table :gifts, id: :uuid do |t|
      t.references :product, type: :uuid, null: false, foreign_key: true
      t.references :license, type: :uuid, foreign_key: true
      t.string :code, null: false
      t.string :stripe_session_id, null: false
      t.string :stripe_payment_intent, null: false
      t.string :price_id
      t.integer :quantity
      t.string :update_policy
      t.string :tier
      t.integer :regional_band
      t.string :regional_country
      t.integer :amount_cents
      t.string :currency
      t.string :buyer_email, null: false
      t.string :to_name
      t.string :from_name
      t.string :note
      t.datetime :emailed_at
      t.datetime :redeemed_at
      t.datetime :refunded_at
      t.timestamps
    end
    add_index :gifts, :code, unique: true
    add_index :gifts, :stripe_session_id, unique: true
    add_index :gifts, :stripe_payment_intent, unique: true

    add_column :products, :gift_card_url, :string
    add_column :products, :gift_transactional_id, :string
  end
end
