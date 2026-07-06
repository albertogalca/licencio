class AddTrialToLicenses < ActiveRecord::Migration[8.1]
  def change
    add_column :licenses, :trial, :boolean, default: false, null: false
  end
end
