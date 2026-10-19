require "test_helper"

# A license keeps the band it was bought at: it renews and upgrades there, whatever country its
# owner is in by then.
class LicenseRegionalBandTest < ActiveSupport::TestCase
  Price = Struct.new(:id, :product, :metadata, :unit_amount, :nickname, :currency, :lookup_key)

  setup do
    @product = products(:cozy)
    @product.update!(stripe_product_id: "prod_cozy", stripe_secret_key: "sk_test_cozy",
      stripe_webhook_secret: "whsec_cozy", checkout_success_url: "https://cozy.example/thanks",
      checkout_cancel_url: "https://cozy.example/#pricing",
      renewal_stripe_price_id: "price_renewal_1", lifetime_stripe_price_id: "price_forever_upgrade_1")
    @prices = {}
    { "standard" => [ 4900, 3900, 2900, 1900, 1200 ], "renewal" => [ 2400, 1900, 1400, 900, 600 ],
      "forever_upgrade" => [ 3900, 3000, 2600, 1600, 1000 ] }.each do |sku, amounts|
      amounts.each.with_index(1) do |amount, band|
        metadata = { "sku" => sku, "band" => band.to_s, "seats" => "unlimited" }
        metadata["renewal"] = "1" unless sku == "standard"
        key = @product.band_lookup_key(sku, band)
        @prices["price_#{sku}_#{band}"] = Price.new("price_#{sku}_#{band}", "prod_cozy", metadata, amount, key, "usd", key)
      end
    end
  end

  test "a band license renews at its band's renewal price" do
    license = annual(regional_band: 3, stripe_price_id: "price_standard_3")
    with_stripe { assert_equal "price_renewal_3", license.renewal_price_id }
  end

  test "a license from before bands, or from band 1, renews at the product's column" do
    with_stripe do
      assert_equal "price_renewal_1", annual(regional_band: nil).renewal_price_id
      assert_equal "price_renewal_1", annual(regional_band: 1).renewal_price_id
    end
  end

  test "the grandfather clause still wins over the band" do
    @prices["price_35_era"] = Price.new("price_35_era", "prod_cozy", { "renewal_price" => "price_renew_17" })
    license = annual(regional_band: 4, stripe_price_id: "price_35_era")
    with_stripe { assert_equal "price_renew_17", license.renewal_price_id }
  end

  test "a band price Stripe lacks leaves the renewal on the column instead of refusing it" do
    @prices.delete("price_renewal_3")
    with_stripe { assert_equal "price_renewal_1", annual(regional_band: 3).renewal_price_id }
  end

  test "the Forever upgrade is the band's own upgrade price" do
    license = annual(regional_band: 4)
    session_price = nil
    with_stripe(create: ->(params, *_) { session_price = params[:line_items].first[:price]; :session }) do
      assert_equal :session, license.renewal_checkout(kind: :forever)
    end
    assert_equal "price_forever_upgrade_4", session_price

    with_stripe(create: ->(params, *_) { session_price = params[:line_items].first[:price]; :session }) do
      annual(regional_band: nil).renewal_checkout(kind: :forever)
    end
    assert_equal "price_forever_upgrade_1", session_price
  end

  test "an owner cannot renew or upgrade through another band's price" do
    license = annual(regional_band: nil)
    assert_not license.renewable_with?(@prices["price_renewal_5"])
    assert_not license.renewable_with?(@prices["price_forever_upgrade_5"])
    assert license.renewable_with?(@prices["price_renewal_1"])

    with_stripe do
      assert_raises(Product::CheckoutNotConfigured) do
        @product.create_checkout_session(price_id: "price_renewal_5", email: nil, renew_license_key: license.license_key)
      end
    end
  end

  test "no license without a price recorded renews at the cheapest band" do
    @product.update!(renewal_stripe_price_id: nil)
    license = annual(regional_band: nil, stripe_price_id: nil, max_activations: nil)
    with_stripe { assert_equal "price_standard_1", license.renewal_price_id }
  end

  test "fulfilment keeps the band on the license and the vouched country on the payment" do
    session = Stripe::Checkout::Session.construct_from(id: "cs_br", payment_intent: "pi_br", customer: "cus_br",
      amount_total: 14900, currency: "brl", customer_details: { email: "ana@example.com", name: "Ana" },
      metadata: { licencio_product_id: @product.id, quantity: "", price_id: "price_standard_3",
                  update_policy: "time_limited", regional_band: "3", regional_country: "BR" })
    line_items = Struct.new(:data).new([ Struct.new(:price).new(@prices["price_standard_3"]) ])

    license = Stripe::Checkout::Session.stub(:list_line_items, line_items) do
      License.fulfill_from_stripe_session(@product, session)
    end

    assert_equal 3, license.regional_band
    assert_equal "BR", license.payments.sole.regional_country
    assert_equal "brl", license.payments.sole.currency
  end

  test "a renewal keeps the band it was sold at" do
    license = annual(regional_band: 3)
    license.renew!(stripe_payment_id: "pi_renew", price_id: "price_renewal_3", amount_cents: 7500, currency: "brl")
    assert_equal 3, license.reload.regional_band
  end

  test "the backfill gives a license paid in an old discount currency its country's band" do
    brl = paid(currency: "brl")
    inr = paid(currency: "inr")
    eur = paid(currency: "eur")
    usd = paid(currency: "usd")
    set = paid(currency: "brl", regional_band: 1)

    counts = License.backfill_regional_bands!(@product, dry_run: true)
    assert_nil brl.reload.regional_band, "a dry run writes nothing"
    assert_equal 1, counts["band 3"]

    License.backfill_regional_bands!(@product, dry_run: false)
    assert_equal 3, brl.reload.regional_band
    assert_equal 5, inr.reload.regional_band
    assert_nil eur.reload.regional_band, "the euro was never discounted"
    assert_nil usd.reload.regional_band
    assert_equal 1, set.reload.regional_band, "a license with a band is never touched"

    assert_no_changes -> { License.where.not(regional_band: nil).count } do
      License.backfill_regional_bands!(@product, dry_run: false)
    end
  end

  private
    def annual(regional_band:, stripe_price_id: "price_standard_1", max_activations: nil)
      @product.licenses.create!(status: "active", update_policy: "time_limited", max_activations:,
        expires_at: 1.day.ago, regional_band:, stripe_price_id:, customer: customers(:alberto))
    end

    def paid(currency:, regional_band: nil)
      annual(regional_band:).tap do |license|
        license.payments.create!(stripe_payment_intent: "pi_#{SecureRandom.hex(4)}", kind: "purchase",
          amount_cents: 1000, currency:)
      end
    end

    def with_stripe(create: ->(*) { :session }, &)
      retrieve = ->(id, *_) { @prices.fetch(id) { raise Stripe::InvalidRequestError.new("No such price", "id") } }
      list = lambda do |params, *_|
        found = @prices.values.select { |p| p.lookup_key }
        found = found.select { |p| params[:lookup_keys].include?(p.lookup_key) } if params[:lookup_keys]
        Struct.new(:data).new(found)
      end
      Stripe::Price.stub(:retrieve, retrieve) do
        Stripe::Price.stub(:list, list) do
          Stripe::Checkout::Session.stub(:create, create, &)
        end
      end
    end
end
