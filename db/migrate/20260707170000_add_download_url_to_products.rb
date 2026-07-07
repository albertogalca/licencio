class AddDownloadUrlToProducts < ActiveRecord::Migration[8.1]
  def change
    add_column :products, :download_url, :string
  end
end
