class AddAffiliateCommissionPercentToProducts < ActiveRecord::Migration[8.1]
  # Nullable: null → fall back to the affiliate's own commission_percent (global default 20).
  # Set per product to override (e.g. Picmal pays 25).
  def change
    add_column :products, :affiliate_commission_percent, :integer
  end
end
