# Reports a sale to the product's GA4 property. Its own job so a GA4 outage never holds up
# fulfillment. Retries reuse the transaction id, which GA4 asks for to avoid counting a sale twice.
class PurchaseAnalyticsJob < ApplicationJob
  def perform(product, reference:, transaction_id:, amount:, currency:, item:)
    visitor = GoogleAnalytics::Visitor.parse(reference)
    return unless visitor && product.reports_purchases?
    GoogleAnalytics.send_purchase(measurement_id: product.ga4_measurement_id,
      api_secret: product.ga4_api_secret, visitor:, transaction_id:, amount:, currency:, item:)
  end
end
