# Generates Cozy's country -> band table from the two approved inputs beside this file, into
# every place that reads it. One generator, so licencio and the site can never disagree.
#
#   ruby scripts/regional_bands.rb                                  # licencio only
#   ruby scripts/regional_bands.rb --site ../cozy-marketing         # and the site middleware
#
# Inputs (scripts/regional_bands/), decided 2026-10-19:
#   tiers-final.csv  iso2 -> band 1..5. A country not listed is band 1.
#   stripe.csv       Standard and Forever, per currency and band, already rounded.
#
# Outputs:
#   config/regional_bands/cozy.json        read by Product::RegionalPricing and scripts/stripe_prices.rb
#   <site>/src/lib/regionalBands.ts        read by the site's functions/_middleware.ts
#
# Band 1 is the full price and carries no currency options: a band 1 country pays USD, or
# Adaptive Pricing's conversion of it, exactly as it did before bands. Bands 2 to 5 carry an
# option for every currency one of their countries pays in.

require "csv"
require "json"

ROOT = File.expand_path("..", __dir__)
INPUTS = File.join(__dir__, "regional_bands")
SLUG = "cozy"

BANDS = (1..5).to_a.freeze
DISCOUNT = { 1 => 0.00, 2 => 0.20, 3 => 0.40, 4 => 0.60, 5 => 0.75 }.freeze

# USD, the approved prices. The renewal is half of Standard, floored, the rule that made $24.
# The Forever upgrade is Forever minus Standard, so Standard plus the upgrade lands on Forever in
# every band. Band 1 keeps the live $39, one under that rule, and is not repriced here.
USD = {
  "standard" => { 1 => 49, 2 => 39, 3 => 29, 4 => 19, 5 => 12 },
  "forever" => { 1 => 89, 2 => 69, 3 => 55, 4 => 35, 5 => 22 }
}.freeze
RENEWAL_BASE = 24
BAND_ONE_UPGRADE = 39

# Who pays in which currency. Only currencies stripe.csv prices are listed; every other country
# pays its band's USD amount through Adaptive Pricing. Bulgaria uses the euro since 2026-01-01.
CURRENCY_COUNTRIES = {
  "EUR" => %w[AT BE BG HR CY EE FI FR DE GR IE IT LV LT LU MT NL PT SK SI ES AD MC SM ME XK],
  "AUD" => %w[AU NR KI TV], "CHF" => %w[CH LI], "DKK" => %w[DK FO GL], "NZD" => %w[NZ],
  "GBP" => %w[GB IM JE GG GI],
  "CAD" => %w[CA], "JPY" => %w[JP], "INR" => %w[IN], "BRL" => %w[BR], "MXN" => %w[MX],
  "PLN" => %w[PL], "SEK" => %w[SE], "NOK" => %w[NO], "TRY" => %w[TR], "ZAR" => %w[ZA],
  "KRW" => %w[KR], "IDR" => %w[ID], "PHP" => %w[PH], "CZK" => %w[CZ], "HUF" => %w[HU],
  "RON" => %w[RO], "SGD" => %w[SG], "HKD" => %w[HK], "TWD" => %w[TW], "CNY" => %w[CN],
  "ILS" => %w[IL], "AED" => %w[AE], "SAR" => %w[SA], "MYR" => %w[MY], "THB" => %w[TH],
  "VND" => %w[VN], "ARS" => %w[AR], "CLP" => %w[CL], "COP" => %w[CO], "PEN" => %w[PE],
  "EGP" => %w[EG], "PKR" => %w[PK], "NGN" => %w[NG], "BDT" => %w[BD], "UAH" => %w[UA],
  "MAD" => %w[MA], "KES" => %w[KE], "LKR" => %w[LK]
}.freeze

# Stripe reads unit_amount in whole units for these. Every other currency here is in cents.
ZERO_DECIMAL = %w[CLP JPY KRW VND].freeze
# Priced in round thousands or hundreds where minor units mean nothing (ppp/prices.py TWO_SIG).
TWO_SIG = %w[JPY KRW IDR VND HUF CLP COP TWD].freeze
# Stripe's ceiling on a unit_amount.
MAX_UNIT_AMOUNT = 99_999_999

# The rounding rule the approved Standard and Forever amounts came from (ppp/prices.py), used
# here only for the renewal, the one local amount stripe.csv does not carry.
def charm(x)
  ladder =
    if x < 100
      (1..19).to_a + [ 22 ] + (20..99).select { |v| [ 5, 9 ].include?(v % 10) }
    else
      step = 10**(Math.log10(x).floor - 1)
      base = (x / step).floor
      ((base - 1)..(base + 2)).map { |n| n * step - 1 }
    end
  ladder.min_by { |v| [ (v - x).abs, -v ] }
end

def two_sig(x)
  mag = 10**(Math.log10(x).floor - 1)
  (x / mag).round(half: :even) * mag
end

def local_price(usd, currency, rate)
  x = usd * rate
  TWO_SIG.include?(currency) ? two_sig(x) : charm(x)
end

def unit_amount(major, currency)
  amount = ZERO_DECIMAL.include?(currency) ? major : major * 100
  raise "#{currency} #{major} is over Stripe's unit_amount ceiling" if amount > MAX_UNIT_AMOUNT
  amount
end

countries = CSV.read(File.join(INPUTS, "tiers-final.csv"), headers: true)
  .to_h { |row| [ row["iso2"], Integer(row["tier"]) ] }
abort "a band outside 1..5 in tiers-final.csv" unless countries.values.all? { |b| BANDS.include?(b) }

stripe_rows = CSV.read(File.join(INPUTS, "stripe.csv"), headers: true)
  .reject { |row| row["currency"] == "USD" }
  .group_by { |row| row["currency"] }
  .transform_values { |rows| rows.to_h { |row| [ Integer(row["tier"]), row ] } }

currency_of = CURRENCY_COUNTRIES.flat_map { |cur, isos| isos.map { |iso| [ iso, cur ] } }.to_h
missing = CURRENCY_COUNTRIES.keys - stripe_rows.keys
abort "stripe.csv has no rows for #{missing.join(", ")}" if missing.any?

usd = BANDS.to_h do |band|
  standard = USD["standard"][band]
  forever = USD["forever"][band]
  [ band, { "standard" => standard, "forever" => forever,
            "renewal" => (RENEWAL_BASE * (1 - DISCOUNT[band])).floor,
            "forever_upgrade" => band == 1 ? BAND_ONE_UPGRADE : forever - standard } ]
end

# A band's currencies are the ones its own countries pay in. A currency shared across bands
# (the euro) gets an option in each band that has one of its countries.
band_currencies = BANDS.to_h do |band|
  [ band, countries.select { |iso, b| b == band && band > 1 && currency_of[iso] }
                   .map { |iso, _| currency_of[iso] }.uniq.sort ]
end

local = BANDS.to_h do |band|
  options = band_currencies[band].to_h do |cur|
    row = stripe_rows.fetch(cur).fetch(band)
    standard = Integer(row["standard_local"])
    forever = Integer(row["forever_local"])
    renewal = local_price(RENEWAL_BASE * (1 - DISCOUNT[band]), cur, Float(row["fx_per_usd"]))
    [ cur, { "standard" => standard, "forever" => forever, "renewal" => renewal,
             "forever_upgrade" => forever - standard } ]
  end
  [ band, options ]
end

banded = countries.select { |_, band| band > 1 }.sort.to_h
pinned = banded.filter_map { |iso, band| [ iso, currency_of[iso] ] if band_currencies[band].include?(currency_of[iso]) }.to_h

licencio = {
  "generated_by" => "scripts/regional_bands.rb, from scripts/regional_bands/{tiers-final,stripe}.csv",
  "countries" => banded,
  "currencies" => pinned.transform_values(&:downcase),
  "bands" => BANDS.to_h do |band|
    [ band.to_s, {
      "discount" => DISCOUNT[band],
      "usd" => usd[band].transform_values { |major| unit_amount(major, "USD") },
      "currency_options" => local[band].to_h do |cur, amounts|
        [ cur.downcase, amounts.transform_values { |major| unit_amount(major, cur) } ]
      end
    } ]
  end
}

out = File.join(ROOT, "config/regional_bands/#{SLUG}.json")
File.write(out, JSON.pretty_generate(licencio) + "\n")
puts "wrote #{out} (#{banded.size} countries in bands 2 to 5)"

if (i = ARGV.index("--site"))
  site = File.expand_path(ARGV.fetch(i + 1))
  display = BANDS.to_h do |band|
    [ band, { "USD" => usd[band].slice("standard", "forever"),
              **local[band].transform_values { |a| a.slice("standard", "forever") } } ]
  end
  ts = <<~TS
    // Generated by licencio scripts/regional_bands.rb from the approved country table. Do not
    // edit: change scripts/regional_bands/*.csv in licencio and run the generator again.
    //
    // A country not in COUNTRY_BAND is band 1, the full price. CURRENCY names the currency a
    // country is charged in when its band has an option for it; any other country is shown
    // and charged the band's USD amount. Amounts are in whole currency units.

    export type Band = 1 | 2 | 3 | 4 | 5;

    export const COUNTRY_BAND: Record<string, Band> = #{JSON.generate(banded)};

    export const CURRENCY: Record<string, string> = #{JSON.generate(pinned)};

    export const PRICES: Record<Band, Record<string, { standard: number; forever: number }>> = #{JSON.generate(display)};
  TS
  path = File.join(site, "src/lib/regionalBands.ts")
  File.write(path, ts)
  puts "wrote #{path}"
end
