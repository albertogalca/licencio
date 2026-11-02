class CreateRedemptionCodes < ActiveRecord::Migration[8.1]
  def change
    create_table :redemption_codes, id: :uuid do |t|
      t.references :product, type: :uuid, null: false, foreign_key: true
      t.references :customer, type: :uuid, foreign_key: true
      t.references :license, type: :uuid, foreign_key: true
      t.string :code_digest, null: false
      t.string :code_hint, null: false
      t.string :source, null: false
      t.string :status, null: false, default: "unredeemed"
      t.datetime :redeemed_at
      t.datetime :revoked_at
      t.timestamps
    end
    add_index :redemption_codes, :code_digest, unique: true
    add_index :redemption_codes, [ :product_id, :source, :status ]

    add_column :products, :redemption_transactional_id, :string
    add_column :products, :seats_added_transactional_id, :string
  end
end
