class CreateAppStoreCharges < ActiveRecord::Migration[8.1]
  def change
    create_table :app_store_charges, id: :uuid do |t|
      t.references :product, type: :uuid, null: false, foreign_key: true, index: false
      t.string :store_product_id, null: false
      t.string :transaction_id, null: false
      t.string :original_transaction_id, null: false
      t.string :app_transaction_id
      t.string :bundle_id
      t.string :environment, null: false
      t.datetime :purchased_at, null: false
      t.integer :amount_cents
      t.string :currency
      t.string :storefront
      t.datetime :revoked_at
      t.timestamps
    end
    add_index :app_store_charges, :transaction_id, unique: true
    add_index :app_store_charges, [ :product_id, :app_transaction_id ]
  end
end
