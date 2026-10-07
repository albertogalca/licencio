# The key a bundle store uses to mint licenses. Kept apart from api_key because api_key ships
# inside every desktop build and is therefore public. Nullable: a product with none can't issue.
class AddIssuanceApiKeyToProducts < ActiveRecord::Migration[8.1]
  def change
    add_column :products, :issuance_api_key, :string
    add_index :products, :issuance_api_key, unique: true
  end
end
