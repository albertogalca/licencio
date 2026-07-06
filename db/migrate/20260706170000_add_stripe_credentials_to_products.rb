class AddStripeCredentialsToProducts < ActiveRecord::Migration[8.1]
  def change
    add_column :products, :stripe_secret_key, :string
    add_column :products, :stripe_webhook_secret, :string
  end
end
