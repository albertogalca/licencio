require "test_helper"

class Product::RegionalPricingTest < ActiveSupport::TestCase
  Price = Struct.new(:id, :product, :metadata, :unit_amount, :nickname, :currency, :lookup_key)

  setup do
    @product = products(:cozy)
    @product.update!(stripe_product_id: "prod_cozy", stripe_secret_key: "sk_test_cozy",
      stripe_webhook_secret: "whsec_cozy", checkout_success_url: "https://cozy.example/thanks",
      checkout_cancel_url: "https://cozy.example/#pricing", region_token_secret: "shared-with-the-site")
    @prices = {}
    { "standard" => [ 4900, 3900, 2900, 1900, 1200 ], "forever" => [ 8900, 6900, 5500, 3500, 2200 ],
      "renewal" => [ 2400, 1900, 1400, 900, 600 ], "forever_upgrade" => [ 3900, 3000, 2600, 1600, 1000 ] }.each do |sku, amounts|
      amounts.each.with_index(1) { |amount, band| add_price(sku, band, amount) }
    end
  end

  test "a signed country from the site is trusted for a day and no longer" do
    assert_equal "BR", @product.region_country(token("BR"))
    assert_equal "BR", @product.region_country(token("BR", at: 23.hours.ago))
    assert_nil @product.region_country(token("BR", at: 25.hours.ago)), "a day-old link is full price"
    assert_nil @product.region_country(token("BR", at: 1.hour.from_now)), "a token from the future is forged"
  end

  test "a token that was not signed with the secret, or is not a token, is no country" do
    forged = token("BR").sub(/\ABR/, "PK")
    assert_nil @product.region_country(forged), "the country is covered by the signature"
    assert_nil @product.region_country(token("BR", secret: "guessed"))
    [ nil, "", "BR", "BR.123", "br.#{Time.current.to_i}.x", "BR.notanumber.x" ].each do |junk|
      assert_nil @product.region_country(junk), junk.inspect
    end
  end

  test "regional pricing is off without the secret, and for a product without a band table" do
    valid = token("BR")
    @product.update!(region_token_secret: nil)
    assert_nil @product.region_country(valid)

    picmal = products(:picmal)
    picmal.update!(region_token_secret: "shared-with-the-site")
    assert_not picmal.regional_pricing?
    assert_nil picmal.region_country(token("BR"))
  end

  test "bands come from the approved table, and an unlisted country is full price" do
    assert_equal 3, @product.band_for("CN"), "China is band 3 (decided 2026-10-19)"
    assert_equal 3, @product.band_for("BR")
    assert_equal 2, @product.band_for("ES")
    assert_equal 5, @product.band_for("IN")
    assert_equal 1, @product.band_for("DE")
    assert_equal 1, @product.band_for("US")
    assert_equal 1, @product.band_for("ZZ")
    assert_equal 1, @product.band_for(nil)
    assert_equal "eur", @product.regional_currency("ES")
    assert_nil @product.regional_currency("DE"), "band 1 pins no currency"
  end

  test "checkout swaps the storefront price for the visitor's band and charges the currency the page showed" do
    params = checkout(price_id: id_for("standard", 1), region: token("BR"))

    assert_equal [ { price: id_for("standard", 3), quantity: 1 } ], params[:line_items]
    assert_equal "brl", params[:currency]
    assert_equal 3, params[:metadata][:regional_band]
    assert_equal "BR", params[:metadata][:regional_country]
    assert_equal id_for("standard", 3), params[:metadata][:price_id]
    assert_equal true, params[:allow_promotion_codes], "band prices take codes (decided 2026-10-19)"
  end

  test "a band country with no currency of its own pays the band's USD amount" do
    params = checkout(price_id: id_for("forever", 1), region: token("AL"))
    assert_equal 3, @product.band_for("AL")
    assert_equal id_for("forever", 3), params[:line_items].first[:price]
    assert_not params.key?(:currency), "Stripe converts the band's USD amount"
  end

  test "no token, a forged one, or a band 1 country is full price" do
    [ nil, token("PK", secret: "guessed"), token("DE") ].each do |region|
      params = checkout(price_id: id_for("standard", 1), region:)
      assert_equal id_for("standard", 1), params[:line_items].first[:price], region.inspect
      assert_not params.key?(:currency)
      assert_equal 1, params[:metadata][:regional_band]
    end
  end

  test "a cheaper band's price id copied out of a checkout charges the visitor's own band" do
    params = checkout(price_id: id_for("standard", 5))
    assert_equal id_for("standard", 1), params[:line_items].first[:price]

    params = checkout(price_id: id_for("standard", 5), region: token("ES"))
    assert_equal id_for("standard", 2), params[:line_items].first[:price]
  end

  test "a band price Stripe does not have falls back to full price instead of failing the sale" do
    @prices.delete(id_for("standard", 3))
    params = checkout(price_id: id_for("standard", 1), region: token("BR"))
    assert_equal id_for("standard", 1), params[:line_items].first[:price]
    assert_not params.key?(:currency), "band 1 pins no currency"
  end

  test "a currency Stripe refuses is dropped and the checkout still opens" do
    attempts = []
    create = lambda do |params, *_|
      attempts << params
      raise Stripe::InvalidRequestError.new("currency not supported", "currency") if params.key?(:currency)
      :session
    end
    with_stripe(create:) do
      assert_equal :session, @product.create_checkout_session(price_id: id_for("standard", 1), email: nil, region: token("IN"))
    end
    assert_equal [ "inr", nil ], attempts.map { |p| p[:currency] }
    assert_equal id_for("standard", 5), attempts.last[:line_items].first[:price], "still the band price"
  end

  test "prices without band metadata, like Picmal's, pass through untouched" do
    @prices["price_old"] = Price.new("price_old", "prod_cozy", { "seats" => "unlimited", "tier" => "standard" }, 4900)
    params = checkout(price_id: "price_old", region: token("BR"))
    assert_equal "price_old", params[:line_items].first[:price]
    assert_not params.key?(:currency)
    assert_nil params[:metadata][:regional_band]
  end

  test "variants show band 1 only, so the cheapest band never becomes anybody's fallback" do
    with_stripe do
      assert_equal [ id_for("standard", 1), id_for("forever", 1) ], @product.variants.map(&:price_id)
    end
  end

  test "a band upgrade price is a lifetime price, the bare column still works" do
    assert @product.lifetime_price?(@prices[id_for("forever_upgrade", 4)])
    assert_not @product.lifetime_price?(@prices[id_for("renewal", 4)])
    @product.update!(lifetime_stripe_price_id: "price_column")
    assert @product.lifetime_price?(Price.new("price_column", "prod_cozy", {}))
  end

  private
    def add_price(sku, band, amount)
      metadata = { "sku" => sku, "band" => band.to_s, "seats" => "unlimited",
                   "tier" => sku.start_with?("forever") ? "forever" : "standard" }
      metadata["renewal"] = "1" if sku.in?(%w[renewal forever_upgrade])
      key = @product.band_lookup_key(sku, band)
      @prices[id_for(sku, band)] = Price.new(id_for(sku, band), "prod_cozy", metadata, amount, key, "usd", key)
    end

    def id_for(sku, band) = "price_#{sku}_#{band}"

    def token(country, at: Time.current, secret: "shared-with-the-site")
      payload = "#{country}.#{at.to_i}"
      "#{payload}.#{Base64.urlsafe_encode64(OpenSSL::HMAC.digest("SHA256", secret, payload), padding: false)}"
    end

    def with_stripe(create: ->(*) { :session }, &)
      retrieve = ->(id, *_) { @prices.fetch(id) { raise Stripe::InvalidRequestError.new("No such price", "id") } }
      list = lambda do |params, *_|
        found = @prices.values.select { |p| p.product == "prod_cozy" }
        found = found.select { |p| params[:lookup_keys].include?(p.lookup_key) } if params[:lookup_keys]
        Struct.new(:data).new(found.sort_by(&:unit_amount).reverse)
      end
      Stripe::Price.stub(:retrieve, retrieve) do
        Stripe::Price.stub(:list, list) do
          Stripe::Checkout::Session.stub(:create, create, &)
        end
      end
    end

    def checkout(**args)
      captured = nil
      with_stripe(create: ->(params, *_) { captured = params; :session }) do
        @product.create_checkout_session(email: nil, **args)
      end
      captured
    end
end
