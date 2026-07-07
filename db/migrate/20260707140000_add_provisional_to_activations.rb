class AddProvisionalToActivations < ActiveRecord::Migration[8.1]
  def change
    add_column :activations, :provisional, :boolean, default: false, null: false
  end
end
