class AddPosthogApiKeyToProducts < ActiveRecord::Migration[8.1]
  # Nullable: blank and no POSTHOG_API_KEY_DEFAULT means purchases aren't reported
  # to PostHog (current behaviour). Set to a project write key (phc_...) to close
  # the loop between the marketing site's pageviews and a completed purchase.
  def change
    add_column :products, :posthog_api_key, :string
  end
end
