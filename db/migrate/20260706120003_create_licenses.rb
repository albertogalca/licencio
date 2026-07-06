class CreateLicenses < ActiveRecord::Migration[8.1]
  def change
    create_table :licenses, id: :uuid do |t|
      t.string :license_key, null: false
      t.references :product, null: false, foreign_key: true, type: :uuid
      t.references :customer, null: true, foreign_key: true, type: :uuid
      t.string :status, null: false
      t.string :migration_source
      t.integer :max_activations, null: false
      t.datetime :expires_at
      t.string :stripe_payment_id
      t.datetime :claimed_at

      t.timestamps
    end

    add_index :licenses, :license_key, unique: true
  end
end
