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
# as this is worth, and the currency list is the whole policy.
#
# PPP rides as `currency_options` ON the standard price — per-currency amounts that
# Stripe Checkout picks automatically from the buyer's location. One price ID, no
# separate discounted link to leak. Every band country has its own currency, which is
# what makes this mapping clean (a shared currency like EUR could not be banded).
# A currency_options entry is WRITE-ONCE on Stripe: the script only ever adds
# currencies that are missing, and the amounts below must be right the first time.
PPP_BANDS = {
  # ~upper-middle-income → target $29 of value
  "a" => { target_usd: 29, currencies: %w[BRL MXN TRY PLN RON ARS CLP MYR THB ZAR COP PEN] },
  # ~lower-income → target $19 of value
  "b" => { target_usd: 19, currencies: %w[INR IDR PHP VND EGP PKR NGN BDT UAH MAD KES LKR] }
}.freeze

# Stripe treats these as zero-decimal: unit_amount is whole currency units.
ZERO_DECIMAL = %w[CLP VND].freeze

# Round DOWN to a clean local number — Cozy sells round prices, not .99 charm.
def round_price(x)
  step = case x
  when 0...50 then 1
  when 50...200 then 5
  when 200...1_000 then 10
  when 1_000...10_000 then 100
  when 10_000...100_000 then 1_000
  else 10_000
  end
  (x / step).floor * step
end

# `seats` is required by Product#create_checkout_session, and Cozy's whole promise is
# unlimited devices — so every price says so explicitly rather than relying on a default.
# `tier` is what opts a sale into the unlock flow (Purchase.record_stripe!); `update_policy`
# is what the license-key system reads to decide lifetime vs. a year of updates.
PRICES = [
  { lookup_key: "cozy_standard_usd", nickname: "Cozy — one year of updates", amount: 4900,
    metadata: { "tier" => "standard", "update_policy" => "time_limited", "seats" => "unlimited" } },
  { lookup_key: "cozy_forever_usd", nickname: "Cozy Forever — every update, always", amount: 8900,
    metadata: { "tier" => "forever", "update_policy" => "lifetime", "seats" => "unlimited" } }
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

# ── PPP currency_options on the standard price ──────────────────────────────────
standard = existing["cozy_standard_usd"] ||
  Stripe::Price.list({ product: stripe_product_id, active: true, lookup_keys: [ "cozy_standard_usd" ] }, OPTS).data.first
if standard
  full = Stripe::Price.retrieve({ id: standard.id, expand: [ "currency_options" ] }, OPTS)
  present = (full.currency_options&.keys || []).map(&:to_s).map(&:upcase)
  fx = JSON.parse(Net::HTTP.get(URI("https://open.er-api.com/v6/latest/USD"))).fetch("rates")
  additions = {}
  PPP_BANDS.each do |band, config|
    config[:currencies].each do |cur|
      next if present.include?(cur)
      rate = fx[cur] or (warn "  ! no FX rate for #{cur}, skipped"; next)
      local = round_price(config[:target_usd] * rate)
      minor = ZERO_DECIMAL.include?(cur) ? local : local * 100
      additions[cur.downcase] = { unit_amount: minor }
      report("add currency", format("%s %s ≈ $%.2f (band %s, target $%d)",
        cur, local, local / rate.to_f, band.upcase, config[:target_usd]))
    end
  end
  if additions.empty?
    report("keep", "currency_options already complete on #{standard.id}")
  elsif APPLY
    Stripe::Price.update(standard.id, { currency_options: additions }, OPTS)
    puts "  → #{additions.size} currencies added to #{standard.id}"
  end
else
  report("skip", "currency_options — standard price not found (create it first)")
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
