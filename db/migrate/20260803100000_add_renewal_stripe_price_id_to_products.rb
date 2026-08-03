class AddRenewalStripePriceIdToProducts < ActiveRecord::Migration[8.1]
  def change
    add_column :products, :renewal_stripe_price_id, :string
  end
end
