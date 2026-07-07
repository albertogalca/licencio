class AddCheckoutUrlsToProducts < ActiveRecord::Migration[8.1]
  def change
    add_column :products, :checkout_success_url, :string
    add_column :products, :checkout_cancel_url, :string
  end
end
