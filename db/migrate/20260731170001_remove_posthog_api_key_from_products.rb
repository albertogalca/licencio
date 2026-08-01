class RemovePosthogApiKeyFromProducts < ActiveRecord::Migration[8.1]
  def change
    remove_column :products, :posthog_api_key, :string
  end
end
