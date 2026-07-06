class CreateProducts < ActiveRecord::Migration[8.1]
  def change
    create_table :products, id: :uuid do |t|
      t.string :name, null: false
      t.string :slug, null: false
      t.string :bundle_identifier, null: false
      t.string :license_prefix, null: false
      t.string :stripe_product_id
      t.string :loops_api_key
      t.string :loops_transactional_id
      t.string :sender_email
      t.integer :max_activations_default, null: false, default: 3
      t.string :update_policy, null: false
      t.integer :update_duration_days
      t.integer :trial_days
      t.string :api_key, null: false
      t.string :eddsa_private_key, null: false
      t.string :eddsa_public_key, null: false

      t.timestamps
    end

    add_index :products, :slug, unique: true
    add_index :products, :bundle_identifier, unique: true
    add_index :products, :license_prefix, unique: true
    add_index :products, :api_key, unique: true
  end
end
