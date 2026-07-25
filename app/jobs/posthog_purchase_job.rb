class PosthogPurchaseJob < ApplicationJob
  # distinct_id is the marketing site's PostHog id, carried through Stripe as
  # client_reference_id. It's blank for Payment Link purchases (no checkout session came
  # from the site), so fall back to the email. The sale still lands in revenue totals,
  # it just can't join the pageview funnel.
  def perform(product, distinct_id:, email:, amount_cents:, currency:, timestamp: nil)
    api_key = product.posthog_api_key_or_default
    if api_key.blank?
      Rails.logger.warn("PosthogPurchaseJob: #{product.slug} has no PostHog API key, " \
        "skipping purchase capture for #{email}")
      return
    end
    Posthog.capture(api_key:, distinct_id: distinct_id.presence || email, event: "purchase_completed",
      timestamp:,
      properties: {
        product: product.slug,
        amount: amount_cents.to_i / 100.0,
        currency: currency&.upcase,
        attributed: distinct_id.present?
      })
  end
end
