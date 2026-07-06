class AddLoopsMagicLinkTransactionalIdToProducts < ActiveRecord::Migration[8.1]
  def change
    add_column :products, :loops_magic_link_transactional_id, :string
  end
end
