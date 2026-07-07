class AddLifecycleTransactionalIdsToProducts < ActiveRecord::Migration[8.1]
  def change
    add_column :products, :refund_transactional_id, :string
    add_column :products, :expiry_reminder_transactional_id, :string
  end
end
