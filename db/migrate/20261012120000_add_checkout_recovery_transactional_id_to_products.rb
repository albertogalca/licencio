class AddCheckoutRecoveryTransactionalIdToProducts < ActiveRecord::Migration[8.1]
  def change
    add_column :products, :checkout_recovery_transactional_id, :string
  end
end
