# A price by country. Each country sits in one of five bands (config/regional_bands/<slug>.json,
# written by scripts/regional_bands.rb), and each band is its own set of Stripe prices, found by
# lookup key and tagged `sku` and `band`. That is what lets Spain and Germany pay different
# prices in the same euro.
#
# The country comes from the marketing site, which knows it from Cloudflare and signs it into the
# buy link. A missing, forged or stale token is band 1, the full price, so the site can only ever
# fail toward full price. A license keeps the band it was bought at for every renewal and
# upgrade after, and never asks the country again.
#
# Off until both halves exist: the table for this slug and the token secret. A product with
# neither (Picmal) sells exactly as before.
module Product::RegionalPricing
  extend ActiveSupport::Concern

  FULL_BAND = 1
  # What a storefront buy link sells. The renewal and the upgrade are owner-only and take their
  # band from the license instead.
  STOREFRONT_SKUS = %w[standard forever].freeze
  # A token is minted on every page view, so a day covers a tab left open overnight and little
  # else. A link copied out of a cheaper country stops working by the next day.
  REGION_TOKEN_TTL = 1.day
  CLOCK_SKEW = 5.minutes

  TABLES = Dir[Rails.root.join("config/regional_bands/*.json")]
    .to_h { |path| [ File.basename(path, ".json"), JSON.parse(File.read(path)).freeze ] }.freeze

  included do
    encrypts :region_token_secret
  end

  def regional_pricing? = TABLES.key?(slug) && region_token_secret.present?

  # The country a buy link vouches for, or nil. Format `CC.issued_at.signature`, the signature
  # being HMAC-SHA256 of `CC.issued_at`, base64url without padding. Mirrors signRegion in the
  # site's functions/_middleware.ts.
  def region_country(token)
    return unless regional_pricing?
    country, issued_at, signature = token.to_s.split(".", 3)
    return unless country.to_s.match?(/\A[A-Z]{2}\z/) && issued_at.to_s.match?(/\A\d{1,12}\z/) && signature
    return unless ActiveSupport::SecurityUtils.secure_compare(signature, region_signature("#{country}.#{issued_at}"))
    age = Time.current.to_i - issued_at.to_i
    country if age.between?(-CLOCK_SKEW.to_i, REGION_TOKEN_TTL.to_i)
  end

  def region_signature(payload)
    Base64.urlsafe_encode64(OpenSSL::HMAC.digest("SHA256", region_token_secret, payload), padding: false)
  end

  def band_for(country) = (regional_table.dig("countries", country.to_s) if country) || FULL_BAND

  # The currency the band's price has an amount for, so checkout charges what the page showed.
  # nil leaves the choice to Stripe.
  def regional_currency(country) = regional_table.dig("currencies", country.to_s)

  def band_lookup_key(sku, band) = "#{slug}_#{sku}_band#{band}"

  # nil when Stripe has no such price, or does not answer. Every caller then falls back to the
  # price it would have used before bands, so a missing band price never costs a sale.
  def band_price(sku, band)
    Stripe::Price.list({ lookup_keys: [ band_lookup_key(sku, band) ], active: true, limit: 1 }, stripe_opts).data.first
  rescue Stripe::StripeError => e
    Rails.logger.warn("regional: #{slug} #{band_lookup_key(sku, band)} unavailable: #{e.message}")
    nil
  end

  # nil for a price from before bands.
  def price_band(price) = price.metadata["band"].presence&.to_i

  # A band price other than band 1 is never a storefront variant: it would headline the buy
  # button and win License#fallback_variant_price_id's cheapest-variant tiebreak.
  def regional_variant?(price) = (price_band(price) || FULL_BAND) != FULL_BAND

  private
    def regional_table = TABLES.fetch(slug, {})

    # The storefront price for this visitor: the same SKU in the visitor's band. Applied to any
    # band-tagged storefront price, in both directions, so a band 5 price id copied out of
    # somebody's checkout charges band 1 to a visitor with no token. Untagged prices pass
    # through, which is every price of a product without bands.
    def regional_storefront_price(price, band)
      sku = price.metadata["sku"]
      return price unless sku.in?(STOREFRONT_SKUS) && price_band(price)
      return price if price_band(price) == band
      band_price(sku, band) || (band == FULL_BAND ? nil : band_price(sku, FULL_BAND)) ||
        raise(ActiveRecord::RecordNotFound, "#{slug} has no #{band_lookup_key(sku, band)} price")
    end
end
