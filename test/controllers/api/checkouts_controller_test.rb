require "test_helper"

class Api::CheckoutsControllerTest < ActionDispatch::IntegrationTest
  BROWSER = { "User-Agent" => "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/19.0 Safari/605.1.15" }.freeze

  setup do
    @product = products(:picmal) # stripe_product_id: prod_picmal_stripe
    ENV["CHECKOUT_SUCCESS_URL"] ||= "https://example.com/success"
    ENV["CHECKOUT_CANCEL_URL"]  ||= "https://example.com/cancel"
  end

  test "creates a checkout session for the chosen variant and passes seats as quantity metadata" do
    price = fake_price("price_3", @product.stripe_product_id, { "seats" => "3" })
    captured = nil
    Stripe::Price.stub(:retrieve, price) do
      Stripe::Checkout::Session.stub(:create, ->(params, _opts = {}) { captured = params; fake_session }) do
        post "/api/checkout", params: { product_slug: @product.slug, price_id: "price_3" }
      end
    end

    assert_response :ok
    assert_equal "https://stripe.test/session", response.parsed_body["url"]
    assert_equal [ { price: "price_3", quantity: 1 } ], captured[:line_items]
    assert_equal 3, captured[:metadata][:quantity]
    assert_equal @product.id, captured[:metadata][:licencio_product_id]
    assert_equal({ enabled: true }, captured[:managed_payments])
    assert_equal true, captured[:allow_promotion_codes]
  end

  test "the site's signed country picks the band price" do
    cozy = products(:cozy)
    cozy.update!(stripe_product_id: "prod_cozy", stripe_secret_key: "sk_test_cozy", stripe_webhook_secret: "whsec",
      checkout_success_url: "https://cozy.example/thanks", checkout_cancel_url: "https://cozy.example/",
      region_token_secret: "shared-with-the-site")
    full = fake_price("price_standard_1", "prod_cozy", { "sku" => "standard", "band" => "1", "seats" => "unlimited" })
    band = fake_price("price_standard_2", "prod_cozy", { "sku" => "standard", "band" => "2", "seats" => "unlimited" })
    payload = "ES.#{Time.current.to_i}"
    region = "#{payload}.#{Base64.urlsafe_encode64(OpenSSL::HMAC.digest("SHA256", "shared-with-the-site", payload), padding: false)}"
    captured = nil
    Stripe::Price.stub(:retrieve, full) do
      Stripe::Price.stub(:list, ->(params, *_) { Struct.new(:data).new(params[:lookup_keys] == [ "cozy_standard_band2" ] ? [ band ] : []) }) do
        Stripe::Checkout::Session.stub(:create, ->(params, _opts = {}) { captured = params; fake_session }) do
          get "/api/checkout", params: { product_slug: "cozy", price_id: "price_standard_1", region: }, headers: BROWSER
        end
      end
    end

    assert_redirected_to "https://stripe.test/session"
    assert_equal "price_standard_2", captured[:line_items].first[:price]
    assert_equal "eur", captured[:currency]
  end

  test "GET redirects the buyer straight to Stripe Checkout and forwards client_reference_id" do
    price = fake_price("price_3", @product.stripe_product_id, { "seats" => "3" })
    captured = nil
    Stripe::Price.stub(:retrieve, price) do
      Stripe::Checkout::Session.stub(:create, ->(params, _opts = {}) { captured = params; fake_session }) do
        get "/api/checkout", params: { product_slug: @product.slug, price_id: "price_3", client_reference_id: "ph_abc" }, headers: BROWSER
      end
    end

    assert_redirected_to "https://stripe.test/session"
    assert_equal "ph_abc", captured[:client_reference_id]
    # Seline reads only this metadata key, so the same id has to ride along under it.
    assert_equal "ph_abc", captured[:metadata][:seline_visitor_id]
  end

  test "forwards affonso_referral into the session metadata" do
    price = fake_price("price_3", @product.stripe_product_id, { "seats" => "3" })
    captured = nil
    Stripe::Price.stub(:retrieve, price) do
      Stripe::Checkout::Session.stub(:create, ->(params, _opts = {}) { captured = params; fake_session }) do
        get "/api/checkout", params: { product_slug: @product.slug, price_id: "price_3", affonso_referral: "aff_123" }, headers: BROWSER
      end
    end
    assert_redirected_to "https://stripe.test/session"
    # Affonso attributes the commission by reading exactly this metadata key.
    assert_equal "aff_123", captured[:metadata][:affonso_referral]
  end

  test "a promo code from the link is applied up front, in place of the coupon field" do
    price = fake_price("price_3", @product.stripe_product_id, { "seats" => "3" })
    captured = nil
    looked_up = nil
    codes = ->(params, _opts = {}) { looked_up = params; Struct.new(:data).new([ Struct.new(:id).new("promo_123") ]) }
    Stripe::Price.stub(:retrieve, price) do
      Stripe::PromotionCode.stub(:list, codes) do
        Stripe::Checkout::Session.stub(:create, ->(params, _opts = {}) { captured = params; fake_session }) do
          post "/api/checkout", params: { product_slug: @product.slug, price_id: "price_3", promo: "PRODUCTHUNT30" }
        end
      end
    end

    assert_response :ok
    assert_equal({ code: "PRODUCTHUNT30", active: true, limit: 1 }, looked_up)
    assert_equal [ { promotion_code: "promo_123" } ], captured[:discounts]
    assert_not captured.key?(:allow_promotion_codes)
  end

  test "an unknown or expired promo code leaves a normal checkout with the coupon field" do
    price = fake_price("price_3", @product.stripe_product_id, { "seats" => "3" })
    captured = nil
    Stripe::Price.stub(:retrieve, price) do
      Stripe::PromotionCode.stub(:list, Struct.new(:data).new([])) do
        Stripe::Checkout::Session.stub(:create, ->(params, _opts = {}) { captured = params; fake_session }) do
          post "/api/checkout", params: { product_slug: @product.slug, price_id: "price_3", promo: "EXPIRED" }
        end
      end
    end

    assert_response :ok
    assert_equal true, captured[:allow_promotion_codes]
    assert_not captured.key?(:discounts)
  end

  test "a failed promo lookup still opens a normal checkout with the coupon field" do
    price = fake_price("price_3", @product.stripe_product_id, { "seats" => "3" })
    captured = nil
    lookup = ->(*) { raise Stripe::APIConnectionError, "connection reset" }
    Stripe::Price.stub(:retrieve, price) do
      Stripe::PromotionCode.stub(:list, lookup) do
        Stripe::Checkout::Session.stub(:create, ->(params, _opts = {}) { captured = params; fake_session }) do
          post "/api/checkout", params: { product_slug: @product.slug, price_id: "price_3", promo: "PRODUCTHUNT30" }
        end
      end
    end

    assert_response :ok
    assert_equal true, captured[:allow_promotion_codes]
    assert_not captured.key?(:discounts)
  end

  test "a promo Stripe refuses falls back to a plain checkout instead of losing the buyer" do
    price = fake_price("price_3", @product.stripe_product_id, { "seats" => "3" })
    calls = []
    create = lambda do |params, _opts = {}|
      calls << params
      raise Stripe::InvalidRequestError.new("This promotion code cannot be redeemed.", "discounts") if params.key?(:discounts)
      fake_session
    end
    Stripe::Price.stub(:retrieve, price) do
      Stripe::PromotionCode.stub(:list, Struct.new(:data).new([ Struct.new(:id).new("promo_123") ])) do
        Stripe::Checkout::Session.stub(:create, create) do
          get "/api/checkout", params: { product_slug: @product.slug, price_id: "price_3", promo: "PRODUCTHUNT30" }, headers: BROWSER
        end
      end
    end

    assert_redirected_to "https://stripe.test/session"
    assert_equal 2, calls.size
    assert_equal true, calls.last[:allow_promotion_codes]
    assert_not calls.last.key?(:discounts)
  end

  test "a renewal takes no code, from the link or the coupon field" do
    license = @product.licenses.create!(status: "active", max_activations: 5, expires_at: 1.day.ago)
    price = fake_price("price_renew", @product.stripe_product_id, { "seats" => "5", "renewal" => "1" })
    captured = nil
    lookup = ->(*) { flunk "a renewal must not look up a promo code" }
    Stripe::Price.stub(:retrieve, price) do
      Stripe::PromotionCode.stub(:list, lookup) do
        Stripe::Checkout::Session.stub(:create, ->(params, _opts = {}) { captured = params; fake_session }) do
          post "/api/checkout", params: { product_slug: @product.slug, price_id: "price_renew",
            renew_license_key: license.license_key, promo: "BLACKFRIDAY" }
        end
      end
    end

    assert_response :ok
    assert_not captured.key?(:discounts)
    assert_not captured.key?(:allow_promotion_codes)
  end

  test "the lifetime upgrade still takes a code from the link" do
    @product.update!(lifetime_stripe_price_id: "price_forever")
    license = @product.licenses.create!(status: "active", max_activations: 5, expires_at: 10.days.from_now)
    price = fake_price("price_forever", @product.stripe_product_id, { "seats" => "5", "renewal" => "true" })
    captured = nil
    Stripe::Price.stub(:retrieve, price) do
      Stripe::PromotionCode.stub(:list, Struct.new(:data).new([ Struct.new(:id).new("promo_bf") ])) do
        Stripe::Checkout::Session.stub(:create, ->(params, _opts = {}) { captured = params; fake_session }) do
          post "/api/checkout", params: { product_slug: @product.slug, price_id: "price_forever",
            renew_license_key: license.license_key, promo: "BLACKFRIDAY" }
        end
      end
    end

    assert_response :ok
    assert_equal [ { promotion_code: "promo_bf" } ], captured[:discounts]
  end

  test "rejects a price that belongs to a different Stripe product" do
    price = fake_price("price_x", "prod_someone_else", { "seats" => "1" })
    Stripe::Price.stub(:retrieve, price) do
      post "/api/checkout", params: { product_slug: @product.slug, price_id: "price_x" }
    end
    assert_response :not_found
  end

  # A crawler lowercased a cached checkout link (Stripe ids are case-sensitive) and
  # the unrescued Stripe 404 came back as a 500 on a public endpoint.
  test "POST with a price_id Stripe does not know is not found, not a 500" do
    Stripe::Price.stub(:retrieve, ->(*) { raise Stripe::InvalidRequestError.new("No such price", "price") }) do
      post "/api/checkout", params: { product_slug: @product.slug, price_id: "price_1tqpce4rpfcaqytyx4bgl8h9" }
    end
    assert_response :not_found
    assert_equal "price_not_found", response.parsed_body["code"]
  end

  # An archived price gets past retrieve and only fails at session creation — same
  # exception class, so the same rescue has to cover it.
  test "GET with a retired price sends the buyer to the pricing page instead of JSON" do
    price = fake_price("price_old", @product.stripe_product_id, { "seats" => "1" })
    Stripe::Price.stub(:retrieve, price) do
      Stripe::Checkout::Session.stub(:create, ->(*) { raise Stripe::InvalidRequestError.new("The price specified is inactive.", "line_items") }) do
        get "/api/checkout", params: { product_slug: @product.slug, price_id: "price_old" }, headers: BROWSER
      end
    end
    assert_redirected_to @product.checkout_cancel_url
  end

  test "GET from a crawler goes to the pricing page and never creates a session" do
    Stripe::Checkout::Session.stub(:create, ->(*) { flunk "a crawler must not create a Stripe session" }) do
      get "/api/checkout", params: { product_slug: @product.slug, price_id: "price_3" },
        headers: { "User-Agent" => "Mozilla/5.0 (compatible; bingbot/2.0; +http://www.bing.com/bingbot.htm)" }
    end
    assert_redirected_to @product.checkout_cancel_url
  end

  test "GET with no user agent never creates a session" do
    Stripe::Checkout::Session.stub(:create, ->(*) { flunk "a request with no user agent must not create a Stripe session" }) do
      get "/api/checkout", params: { product_slug: @product.slug, price_id: "price_3" }
    end
    assert_redirected_to @product.checkout_cancel_url
  end

  test "GET from the fake iOS 13 user agent never creates a session" do
    Stripe::Checkout::Session.stub(:create, ->(*) { flunk "the fake iOS 13 agent must not create a Stripe session" }) do
      get "/api/checkout", params: { product_slug: @product.slug, price_id: "price_3" },
        headers: { "User-Agent" => "Mozilla/5.0 (iPhone; CPU iPhone OS 13_2_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/13.0.3 Mobile/15E148 Safari/604.1" }
    end
    assert_redirected_to @product.checkout_cancel_url
  end

  test "GET with a sorted query string goes to the pricing page and never creates a session" do
    Stripe::Checkout::Session.stub(:create, ->(*) { flunk "a sorted query string must not create a Stripe session" }) do
      get "/api/checkout?price_id=price_3&product_slug=#{@product.slug}", headers: BROWSER
    end
    assert_redirected_to @product.checkout_cancel_url
  end

  test "HEAD from a browser never creates a session" do
    Stripe::Checkout::Session.stub(:create, ->(*) { flunk "a HEAD probe must not create a Stripe session" }) do
      head "/api/checkout", params: { product_slug: @product.slug, price_id: "price_3" }, headers: BROWSER
    end
    assert_response :see_other
  end

  test "missing price_id is a bad request" do
    post "/api/checkout", params: { product_slug: @product.slug }
    assert_response :bad_request
  end

  test "unknown product slug is not found" do
    post "/api/checkout", params: { product_slug: "nope", price_id: "price_3" }
    assert_response :not_found
  end

  private
    def fake_price(id, product, metadata)
      Struct.new(:id, :product, :metadata).new(id, product, metadata)
    end

    def fake_session
      Struct.new(:url).new("https://stripe.test/session")
    end
end
