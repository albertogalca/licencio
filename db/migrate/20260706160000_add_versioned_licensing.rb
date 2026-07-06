class AddVersionedLicensing < ActiveRecord::Migration[8.1]
  def change
    add_column :products, :current_version, :integer, null: false, default: 1
    add_column :licenses, :update_policy, :string       # nullable override of product policy
    add_column :licenses, :licensed_version, :integer   # max major version this license updates to
  end
end
