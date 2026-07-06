class CreateCustomers < ActiveRecord::Migration[8.1]
  def change
    create_table :customers, id: :uuid do |t|
      t.string :email, null: false
      t.string :name
      t.string :stripe_customer_id
      t.string :auth_token
      t.datetime :auth_token_expires_at

      t.timestamps
    end

    add_index :customers, :email, unique: true
    add_index :customers, :stripe_customer_id, unique: true
  end
end
