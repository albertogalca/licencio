class AddPurchaseTransactionalIdToProducts < ActiveRecord::Migration[8.1]
  def change
    add_column :products, :purchase_transactional_id, :string
  end
end
