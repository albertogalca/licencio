class AddAppStoreOriginToLicenses < ActiveRecord::Migration[8.1]
  def change
    add_column :licenses, :app_store_original_transaction_id, :string
    add_column :licenses, :app_store_environment, :string
    add_index :licenses, :app_store_original_transaction_id, unique: true,
      where: "app_store_original_transaction_id IS NOT NULL"
  end
end
