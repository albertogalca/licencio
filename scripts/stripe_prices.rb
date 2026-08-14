# Creates Cozy's Stripe prices and the education promotion code.
#
# Dry run (prints what it would create, touches nothing):
#   bin/rails runner scripts/stripe_prices.rb
#
# For real:
#   bin/rails runner scripts/stripe_prices.rb -- --apply
#
# Standalone (no Rails — reads STRIPE_SECRET_KEY and STRIPE_PRODUCT_ID from the env):
#   gem install stripe && ruby scripts/stripe_prices.rb --apply
#
# Under `rails runner` it reads the product's own stripe_secret_key out of the database
# (Stripe is per-Product here — there is no global key).
#
# Idempotent: every price carries a lookup_key, and one that already exists is left alone.
# Safe to re-run after a partial failure.

require "stripe" unless defined?(Stripe)

APPLY = ARGV.include?("--apply")
SLUG  = ENV.fetch("PRODUCT_SLUG", "cozy")

# ── Purchasing-power-parity bands ────────────────────────────────────────────────
# EDIT THESE. They're a judgement call, not a formula: two bands is as much complexity
# as this is worth, and the country list is the whole policy. `ppp_countries` rides in
# the price metadata and the webhook only LOGS a mismatch — nothing is ever blocked.
PPP_BANDS = {
  # ~upper-middle-income
  "a" => { amount: 2900, countries: %w[BR MX TR PL RO AR CL MY TH ZA CO PE] },
  # ~lower-income
  "b" => { amount: 1900, countries: %w[IN ID PH VN EG PK NG BD UA MA KE LK] }
}.freeze

# `seats` is required by Product#create_checkout_session, and Cozy's whole promise is
# unlimited devices — so every price says so explicitly rather than relying on a default.
# `tier` is what opts a sale into the unlock flow (Purchase.record_stripe!); `update_policy`
# is what the license-key system reads to decide lifetime vs. a year of updates.
PRICES = [
  { lookup_key: "cozy_standard_usd", nickname: "Cozy — one year of updates", amount: 4900,
    metadata: { "tier" => "standard", "update_policy" => "time_limited", "seats" => "unlimited" } },
  { lookup_key: "cozy_forever_usd", nickname: "Cozy Forever — every update, always", amount: 8900,
    metadata: { "tier" => "forever", "update_policy" => "lifetime", "seats" => "unlimited" } },
  *PPP_BANDS.map do |band, config|
    { lookup_key: "cozy_standard_ppp_#{band}", nickname: "Cozy — regional (band #{band.upcase})",
      amount: config[:amount],
      metadata: { "tier" => "standard", "update_policy" => "time_limited", "seats" => "unlimited",
                  "ppp_countries" => config[:countries].join(",") } }
  end
].freeze

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

OPTS = { api_key: secret_key }.freeze

def report(action, detail) = puts("#{APPLY ? action : "would #{action}"}  #{detail}")

puts APPLY ? "APPLYING to #{stripe_product_id}" : "DRY RUN — nothing will be created. Pass --apply to execute."
puts

existing = Stripe::Price.list({ product: stripe_product_id, active: true, limit: 100 }, OPTS)
  .data.index_by(&:lookup_key)

PRICES.each do |spec|
  if existing[spec[:lookup_key]]
    report("keep", "#{spec[:lookup_key]} (#{existing[spec[:lookup_key]].id}) already exists")
    next
  end
  report("create price", "#{spec[:lookup_key]} $#{"%.2f" % (spec[:amount] / 100.0)} #{spec[:metadata]}")
  next unless APPLY

  price = Stripe::Price.create({ product: stripe_product_id, currency: "usd",
    unit_amount: spec[:amount], nickname: spec[:nickname], lookup_key: spec[:lookup_key],
    metadata: spec[:metadata] }, OPTS)
  puts "  → #{price.id}"
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
