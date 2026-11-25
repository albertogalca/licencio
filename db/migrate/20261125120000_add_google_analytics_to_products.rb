# A sale is reported to the GA4 property the storefront reports its visits to. Both blank, the
# default, reports nothing.
class AddGoogleAnalyticsToProducts < ActiveRecord::Migration[8.1]
  def change
    add_column :products, :ga4_measurement_id, :string
    add_column :products, :ga4_api_secret, :string
  end
end
