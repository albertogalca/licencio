class AddLifetimeStripePriceIdToProducts < ActiveRecord::Migration[8.1]
  def change
    add_column :products, :lifetime_stripe_price_id, :string
  end
end
