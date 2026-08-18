class DropAffiliateProgram < ActiveRecord::Migration[8.1]
  def up
    remove_reference :payments, :affiliate, if_exists: true
    drop_table :payouts, if_exists: true
    drop_table :affiliate_tokens, if_exists: true
    drop_table :affiliates, if_exists: true
    remove_column :payments, :commission_cents, if_exists: true
    remove_column :products, :affiliate_landing_url, if_exists: true
    remove_column :products, :affiliate_transactional_id, if_exists: true
    remove_column :products, :affiliate_commission_percent, if_exists: true
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
