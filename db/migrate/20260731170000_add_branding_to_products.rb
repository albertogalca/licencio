class AddBrandingToProducts < ActiveRecord::Migration[8.1]
  # All nullable: blank means the portal falls back to the Licencio defaults.
  def change
    add_column :products, :logo_url, :string
    add_column :products, :accent_color, :string
    add_column :products, :background_color, :string
  end
end
