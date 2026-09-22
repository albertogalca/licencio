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
require "json"
require "net/http"

APPLY = ARGV.include?("--apply")
SLUG  = ENV.fetch("PRODUCT_SLUG", "cozy")

# ── Purchasing-power-parity tiers ────────────────────────────────────────────────
# EDIT THESE. They're a judgement call, not a formula.
#
# Three tiers by income, applied to EVERY price as a percentage of its USD amount, so a
# repricing carries the discount with it instead of stranding a hand-set number from the
# era before. Tier 1 (US, UK, Canada, Australia, Japan, Western Europe) pays full price and
# has no entry here.
#
# PPP rides as `currency_options` on each price — per-currency amounts Stripe Checkout picks
# from the buyer's location. One price ID, no separate discounted link to leak. The mapping is
# per CURRENCY, not per country: Spain and Italy belong in tier 2 by income but share EUR with
# Germany and France, so they stay at full price. Everything below has a currency of its own.
#
# Currencies not listed fall through to Stripe Adaptive Pricing, which is a plain FX conversion
# of the USD amount, no discount.
PPP_TIERS = {
  # Mid income → 65% of full price
  2 => { pct: 0.65, currencies: %w[BRL MXN TRY PLN RON ARS CLP MYR THB ZAR PEN] },
  # Low income → 35% of full price
  3 => { pct: 0.35, currencies: %w[INR IDR PHP VND EGP PKR NGN BDT UAH MAD KES LKR COP] }
}.freeze

# Stripe treats these as zero-decimal: unit_amount is whole currency units.
ZERO_DECIMAL = %w[CLP VND].freeze

# Round to two significant figures, so a converted price reads as a decision rather than as
# arithmetic: 1,600 rupees, not 1,588.
def round_price(x)
  return 0 if x <= 0
  mag = 10**(Math.log10(x).floor - 1)
  (x / mag).round * mag
end

# `seats` is required by Product#create_checkout_session, and Cozy's whole promise is
# unlimited devices — so every price says so explicitly rather than relying on a default.
# `tier` is what opts a sale into the unlock flow (Purchase.record_stripe!); `update_policy`
# is what the license-key system reads to decide lifetime vs. a year of updates.
PRICES = [
  { lookup_key: "cozy_standard_usd", nickname: "Cozy — one year of updates", amount: 4900,
    metadata: { "tier" => "standard", "update_policy" => "time_limited", "seats" => "unlimited" } },
  { lookup_key: "cozy_forever_usd", nickname: "Cozy Forever — every update, always", amount: 8900,
    metadata: { "tier" => "forever", "update_policy" => "lifetime", "seats" => "unlimited" } },
  # Half of $49, floored — the same rule that made $35's renew price $17. Becomes
  # `renewal_stripe_price_id` on the cozy product at launch. The `tier` metadata means a
  # renewal session also writes a fresh `purchases` row, which is how a renewal extends
  # the email-unlock window: the unlock always reads the newest purchase for the address.
  { lookup_key: "cozy_renewal_usd", nickname: "Another year of updates (renew, $49 era)", amount: 2400,
    metadata: { "tier" => "standard", "update_policy" => "time_limited", "seats" => "unlimited",
                "renewal" => "1" } },
  # Moving a licence already sold to the lifetime tier. Goes on the cozy product's
  # `lifetime_stripe_price_id`, which is what makes the portal offer it. $39 because
  # 4900 + 3900 = 8800: any lower and buying standard then upgrading undercuts
  # cozy_forever_usd on its own pricing card. `renewal` keeps it owner-only even before
  # the column is set, and `update_policy` is what flips the licence on fulfillment.
  { lookup_key: "cozy_forever_upgrade_usd", nickname: "Cozy Forever upgrade (from Standard)", amount: 3900,
    metadata: { "tier" => "forever", "update_policy" => "lifetime", "seats" => "unlimited",
                "renewal" => "1" } }
].freeze

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

# Metadata on prices that already exist. Only ever ADDS missing keys — an existing value is
# left alone, so re-running can't rewrite a price's meaning under a license already sold.
(PRICES.filter_map { |spec| [ existing[spec[:lookup_key]]&.id, spec[:metadata] ] if existing[spec[:lookup_key]] } +
  LEGACY_RENEWAL_PRICES.to_a +
  GRANDFATHERED_RENEWALS.map { |bought, renews| [ bought, { "renewal_price" => renews } ] }).each do |price_id, wanted|
  current = Stripe::Price.retrieve(price_id, OPTS).metadata.to_h.transform_keys(&:to_s)
  missing = wanted.reject { |k, _| current.key?(k) }
  next if missing.empty?

  report("add metadata", "#{price_id} #{missing}")
  Stripe::Price.update(price_id, { metadata: missing }, OPTS) if APPLY
end

puts

# ── PPP currency_options on every price ─────────────────────────────────────────
#
# A currency_options entry is WRITE-ONCE on Stripe: adding a currency that is missing is
# fine, changing the amount of one already there is refused ("attempting to update an
# immutable field"). So this only ever adds, and prints the drift it cannot fix. Repricing
# an existing band means creating a NEW price with the right amounts, moving the lookup key
# to it (transfer_lookup_key), archiving the old one, and updating src/config/pricing.ts in
# cozy-marketing — which is exactly what happened on 2026-09-22 when the $35-era bands were
# still riding on the $49 standard price.
all_prices = Stripe::Price.list({ product: stripe_product_id, active: true, limit: 100 }, OPTS).data
fx = JSON.parse(Net::HTTP.get(URI("https://open.er-api.com/v6/latest/USD"))).fetch("rates")

all_prices.each do |price|
  next if price.unit_amount.nil?

  usd = price.unit_amount / 100.0
  label = price.lookup_key || price.id
  full = Stripe::Price.retrieve({ id: price.id, expand: [ "currency_options" ] }, OPTS)
  present = (full.currency_options&.to_h || {}).transform_keys { |k| k.to_s.upcase }
  additions = {}

  PPP_TIERS.each do |tier, config|
    config[:currencies].each do |cur|
      rate = fx[cur] or (warn "  ! no FX rate for #{cur}, skipped"; next)
      local = round_price(usd * config[:pct] * rate)
      minor = ZERO_DECIMAL.include?(cur) ? local : local * 100

      if (have = present[cur])
        next if have.unit_amount == minor
        warn format("  ! %s %s is %s, tier %d wants %s — needs a NEW price, Stripe refuses the edit",
          label, cur, have.unit_amount, tier, minor)
        next
      end

      additions[cur.downcase] = { unit_amount: minor }
      report("add currency", format("%s %s %s ≈ $%.2f (tier %d, %d%% of $%.2f)",
        label, cur, local, local / rate.to_f, tier, config[:pct] * 100, usd))
    end
  end

  if additions.empty?
    report("keep", "currency_options already complete on #{label}")
  elsif APPLY
    Stripe::Price.update(price.id, { currency_options: additions }, OPTS)
    puts "  → #{additions.size} currencies added to #{price.id}"
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
