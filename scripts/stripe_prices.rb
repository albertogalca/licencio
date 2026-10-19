# Creates Cozy's Stripe prices, one per SKU and regional band, and the education promotion code.
#
# Plan only, no Stripe call at all (prints the 20 prices from config/regional_bands/cozy.json):
#   ruby scripts/stripe_prices.rb --offline
#
# Dry run (reads Stripe, prints what it would create, touches nothing):
#   bin/rails runner scripts/stripe_prices.rb
#
# For real, in test mode (the product's key is sk_test_...):
#   bin/rails runner scripts/stripe_prices.rb -- --apply
#
# For real, on the live account. Refused without --live, so a test run cannot become a live one
# by accident:
#   bin/rails runner scripts/stripe_prices.rb -- --apply --live
#
# Then, after `rake licenses:backfill_regional_bands[cozy] APPLY=1`, move the product's renewal
# and upgrade columns to the band 1 prices:
#   bin/rails runner scripts/stripe_prices.rb -- --apply --live --move-columns
#
# Standalone (no Rails, reads STRIPE_SECRET_KEY and STRIPE_PRODUCT_ID from the env):
#   gem install stripe && ruby scripts/stripe_prices.rb --apply
#
# Under `rails runner` it reads the product's own stripe_secret_key out of the database
# (Stripe is per-Product here, there is no global key).
#
# Idempotent: every price carries a lookup_key, and one that already exists is left alone.
# Safe to re-run after a partial failure.

require "stripe" unless defined?(Stripe)
require "json"

APPLY = ARGV.include?("--apply")
OFFLINE = ARGV.include?("--offline")
SLUG  = ENV.fetch("PRODUCT_SLUG", "cozy")

# ── Regional bands ───────────────────────────────────────────────────────────────
# One price per (SKU, band), 4 x 5. The amounts come from config/regional_bands/cozy.json, which
# scripts/regional_bands.rb generates from the approved country table. Never edit an amount
# here: change the CSV, run the generator, run this.
#
# This replaced the per-currency PPP_TIERS on 2026-10-19. A currency option is per currency, but
# a band is per country, so Spain and Germany now pay in euros from two different prices. The
# band 1 prices are new too: the old ones carry the tier 2 and 3 currency options, and would hand
# the old discount to any checkout that arrives without a band.
#
# `sku` and `band` are what licencio reads (Product::RegionalPricing): checkout swaps a storefront
# price for the same SKU in the visitor's band, and a license renews at its own band. `tier`,
# `update_policy`, `seats` and `renewal` mean what they always meant, so fulfilment is unchanged.
TABLE = JSON.parse(File.read(File.expand_path("../config/regional_bands/#{SLUG}.json", __dir__)))

SKUS = {
  "standard" => { name: "Cozy Standard",
    metadata: { "tier" => "standard", "update_policy" => "time_limited", "seats" => "unlimited" } },
  "forever" => { name: "Cozy Forever",
    metadata: { "tier" => "forever", "update_policy" => "lifetime", "seats" => "unlimited" } },
  # A renewal session writes a fresh `purchases` row through `tier`, which is how a renewal
  # extends the email-unlock window.
  "renewal" => { name: "Another year of updates",
    metadata: { "tier" => "standard", "update_policy" => "time_limited", "seats" => "unlimited", "renewal" => "1" } },
  # `renewal` keeps it owner-only, `update_policy` flips the license to lifetime on fulfilment.
  "forever_upgrade" => { name: "Cozy Forever upgrade (from Standard)",
    metadata: { "tier" => "forever", "update_policy" => "lifetime", "seats" => "unlimited", "renewal" => "1" } }
}.freeze

BAND_PRICES = TABLE.fetch("bands").flat_map do |band, spec|
  SKUS.map do |sku, config|
    off = (spec.fetch("discount") * 100).round
    { lookup_key: "#{SLUG}_#{sku}_band#{band}",
      nickname: "#{config[:name]}, band #{band}#{" (#{off}% off)" if off.positive?}",
      amount: spec.fetch("usd").fetch(sku),
      currency_options: spec.fetch("currency_options").transform_values { |amounts| amounts.fetch(sku) },
      metadata: config[:metadata].merge("sku" => sku, "band" => band) }
  end
end.freeze

def usd(cents) = format("$%.2f", cents / 100.0)

if OFFLINE
  puts "PLAN, no Stripe call. #{BAND_PRICES.size} prices:"
  BAND_PRICES.each do |spec|
    options = spec[:currency_options].map { |cur, amount| "#{cur} #{amount}" }.join(", ")
    puts "  #{spec[:lookup_key].ljust(30)} #{usd(spec[:amount]).rjust(7)}  #{options.empty? ? "USD only" : options}"
  end
  exit
end

# Renewal SKUs that predate our lookup keys, so they are keyed by price id, each with the
# metadata it needs. `renewal_stripe_price_id` only ever names ONE price, so the moment it moves
# to the $49-era SKU the $17 one would become an ordinary buyable price: a full license for $17.
# The `renewal` flag is what keeps it refused as a license while it stays in service as a renewal.
LEGACY_RENEWAL_PRICES = {
  # The $17 renewal, still in service for the $35 cohort.
  #
  # `tier` is not decoration here: Purchase.record_stripe! returns early for a price that has
  # none, so a renewal at this price extended the license and left the iPhone email-unlock
  # window where it was. The $49-era SKU has carried `tier` since it was created; this one was
  # made before the unlock flow existed.
  "price_1U0I8T8q5jdfnWu2gO7BbBMQ" => {
    "renewal" => "1", "tier" => "standard", "update_policy" => "time_limited"
  }
}.freeze

# Grandfathering, decided 2026-09-16: the $35 era keeps renewing at $17, everybody from the $49
# era on renews at $24. A superseded price names the renewal SKU its own buyers keep, and
# License#renewal_price_id reads it before falling back to the product's current column. So the
# map is written once, here, and the repricing never touches a renewal already sold.
#
# The renewal SKU has to name ITSELF. `renew!` writes the purchased price back onto the license,
# so after one renewal a grandfathered key points at the $17 SKU rather than at the $35 one, and
# without the self-reference year three would quietly fall through to the current column.
#
#   bought at  =>  renews at forever
GRANDFATHERED_RENEWALS = {
  "price_1Tqpdb8q5jdfnWu2XSanPdwF" => "price_1U0I8T8q5jdfnWu2gO7BbBMQ", # $35 "1 year updates" => $17
  "price_1U0I8T8q5jdfnWu2gO7BbBMQ" => "price_1U0I8T8q5jdfnWu2gO7BbBMQ"  # and $17 renews at $17, always
}.freeze

EDU_COUPON_ID = "cozy_edu_40"
EDU_PROMO_CODE = "COZYEDU"

if defined?(Rails)
  product = Product.find_by!(slug: SLUG)
  secret_key = product.stripe_secret_key
  stripe_product_id = product.stripe_product_id
else
  secret_key = ENV.fetch("STRIPE_SECRET_KEY")
  stripe_product_id = ENV.fetch("STRIPE_PRODUCT_ID")
end
abort "#{SLUG} has no stripe_secret_key" if secret_key.to_s.empty?
abort "#{SLUG} has no stripe_product_id" if stripe_product_id.to_s.empty?
if APPLY && secret_key.start_with?("sk_live_", "rk_live_") && !ARGV.include?("--live")
  abort "#{SLUG} holds a LIVE key. Pass --live as well to write to the live account."
end

OPTS = { api_key: secret_key }.freeze

def report(action, detail) = puts("#{APPLY ? action : "would #{action}"}  #{detail}")

puts APPLY ? "APPLYING to #{stripe_product_id} (#{secret_key[0, 8]}...)" : "DRY RUN, nothing will be created. Pass --apply to execute."
puts

existing = {}
Stripe::Price.list({ product: stripe_product_id, active: true, limit: 100, expand: [ "data.currency_options" ] }, OPTS)
  .auto_paging_each { |price| existing[price.lookup_key] = price if price.lookup_key }

BAND_PRICES.each do |spec|
  if (price = existing[spec[:lookup_key]])
    # A currency option is write-once, so drift is printed, never fixed in place: a new amount is
    # a new price (create it, transfer_lookup_key, archive the old one).
    have = (price.currency_options&.to_h || {}).transform_keys(&:to_s).except("usd")
      .transform_values { |option| option[:unit_amount] || option["unit_amount"] }
    drift = spec[:currency_options].reject { |cur, amount| have[cur] == amount }
    warn "  ! #{spec[:lookup_key]} differs from the table: #{drift}. Needs a NEW price." if drift.any? || price.unit_amount != spec[:amount]
    report("keep", "#{spec[:lookup_key]} (#{price.id}) already exists")
    next
  end

  report("create price", "#{spec[:lookup_key]} #{usd(spec[:amount])} + #{spec[:currency_options].size} currencies #{spec[:metadata]}")
  next unless APPLY

  price = Stripe::Price.create({ product: stripe_product_id, currency: "usd",
    unit_amount: spec[:amount], nickname: spec[:nickname], lookup_key: spec[:lookup_key],
    currency_options: spec[:currency_options].transform_values { |amount| { unit_amount: amount } },
    metadata: spec[:metadata] }, OPTS)
  existing[spec[:lookup_key]] = price
  puts "  -> #{price.id}"
end

# Metadata on prices that already exist. Only ever ADDS missing keys: an existing value is left
# alone, so re-running can't rewrite a price's meaning under a license already sold.
(LEGACY_RENEWAL_PRICES.to_a +
  GRANDFATHERED_RENEWALS.map { |bought, renews| [ bought, { "renewal_price" => renews } ] }).each do |price_id, wanted|
  current = Stripe::Price.retrieve(price_id, OPTS).metadata.to_h.transform_keys(&:to_s)
  missing = wanted.reject { |k, _| current.key?(k) }
  next if missing.empty?

  report("add metadata", "#{price_id} #{missing}")
  Stripe::Price.update(price_id, { metadata: missing }, OPTS) if APPLY
end

# The product's columns name band 1's renewal and upgrade. Moved only on request, and only after
# the backfill: until a license has its band, the column is what it renews at, and the old
# column price still carries the old per-currency discount.
if ARGV.include?("--move-columns")
  abort "--move-columns needs rails runner" unless defined?(Rails)
  { renewal_stripe_price_id: "#{SLUG}_renewal_band1", lifetime_stripe_price_id: "#{SLUG}_forever_upgrade_band1" }.each do |column, key|
    target = existing[key]&.id or abort("no #{key} price yet: run with --apply first")
    next if product.public_send(column) == target
    report("move column", "#{column} #{product.public_send(column).inspect} -> #{target}")
    product.update!(column => target) if APPLY
  end
end

puts

# Education pricing: 40% off the standard tier.
#
# NOTE: Stripe scopes a coupon by PRODUCT, not by price — there is no price-level
# restriction — so `applies_to` is the closest it can express, and the code would also
# discount the forever tier if someone found it there. The storefront therefore only ever
# offers the promo field on the standard checkout. Split the tiers into two Stripe products
# if that ever stops being good enough.
coupon = begin
  Stripe::Coupon.retrieve(EDU_COUPON_ID, OPTS)
rescue Stripe::InvalidRequestError
  nil
end

if coupon
  report("keep", "coupon #{EDU_COUPON_ID} already exists")
else
  report("create coupon", "#{EDU_COUPON_ID} — 40% off, restricted to #{stripe_product_id}")
  if APPLY
    coupon = Stripe::Coupon.create({ id: EDU_COUPON_ID, percent_off: 40, duration: "once",
      name: "Cozy education", applies_to: { products: [ stripe_product_id ] } }, OPTS)
    puts "  → #{coupon.id}"
  end
end

promo = Stripe::PromotionCode.list({ code: EDU_PROMO_CODE, limit: 1 }, OPTS).data.first
if promo
  report("keep", "promotion code #{EDU_PROMO_CODE} already exists (#{promo.id})")
else
  report("create promotion code", EDU_PROMO_CODE)
  if APPLY
    promo = Stripe::PromotionCode.create(
      { promotion: { type: "coupon", coupon: EDU_COUPON_ID }, code: EDU_PROMO_CODE }, OPTS)
    puts "  → #{promo.id}"
  end
end

puts
puts APPLY ? "Done." : "Dry run complete. Re-run with --apply to create these."
