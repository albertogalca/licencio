class CreatePortalTokens < ActiveRecord::Migration[8.1]
  def change
    create_table :portal_tokens, id: :uuid do |t|
      t.references :customer, null: false, foreign_key: true, type: :uuid
      t.references :product, null: false, foreign_key: true, type: :uuid
      t.string :token, null: false
      t.datetime :expires_at, null: false
      t.timestamps
    end
    add_index :portal_tokens, :token, unique: true
    add_index :portal_tokens, [ :customer_id, :product_id ], unique: true

    remove_column :customers, :auth_token, :string
    remove_column :customers, :auth_token_expires_at, :datetime
  end
end
