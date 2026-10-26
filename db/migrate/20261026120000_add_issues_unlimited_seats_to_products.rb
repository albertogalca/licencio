class AddIssuesUnlimitedSeatsToProducts < ActiveRecord::Migration[8.1]
  def change
    add_column :products, :issues_unlimited_seats, :boolean, default: false, null: false
  end
end
