require "test_helper"

class ProductTest < ActiveSupport::TestCase
  test "fixtures are valid" do
    assert products(:cozy).valid?
    assert products(:picmal).valid?
  end

  test "customer_count counts distinct buyers, ignoring unclaimed licenses" do
    # cozy has two licenses (one claimed by alberto, one unclaimed/nil customer)
    assert_equal 1, products(:cozy).customer_count
  end

  test "requires name, slug, and update_policy" do
    product = Product.new
    assert_not product.valid?
    assert_includes product.errors.attribute_names, :name
    assert_includes product.errors.attribute_names, :slug
    assert_includes product.errors.attribute_names, :update_policy
  end

  test "time_limited policy requires a positive update_duration_days" do
    product = products(:picmal) # time_limited
    product.update_duration_days = nil
    assert_not product.valid?
    assert_includes product.errors.attribute_names, :update_duration_days
  end

  test "license_expires_at returns nil for a time_limited policy with no duration (no crash)" do
    product = products(:cozy) # lifetime, so update_duration_days is nil
    assert_nil product.update_duration_days
    assert_nil product.license_expires_at(policy: "time_limited")
  end

  test "create_checkout_session fails loud when the redirect URLs are blank" do
    product = products(:picmal)
    product.update_columns(checkout_success_url: nil) # bypass validation, mimic a pre-migration row
    assert_raises(Product::CheckoutNotConfigured) do
      product.create_checkout_session(price_id: "price_x", email: "a@b.com")
    end
  end

  test "a Stripe product id requires its secrets, checkout URLs, and a Loops template" do
    product = products(:cozy) # no stripe_product_id → creds optional
    assert product.valid?

    product.stripe_product_id = "prod_x"
    product.stripe_secret_key = product.stripe_webhook_secret = product.loops_transactional_id = nil
    assert_not product.valid?
    assert_includes product.errors.attribute_names, :stripe_secret_key
    assert_includes product.errors.attribute_names, :stripe_webhook_secret
    assert_includes product.errors.attribute_names, :loops_transactional_id
    assert_includes product.errors.attribute_names, :checkout_success_url
    assert_includes product.errors.attribute_names, :checkout_cancel_url

    product.stripe_secret_key = "sk_test"
    product.stripe_webhook_secret = "whsec_test"
    product.loops_transactional_id = "tmpl_test"
    product.checkout_success_url = "https://x.example/thanks"
    product.checkout_cancel_url = "https://x.example/pricing"
    assert product.valid?
  end

  test "slug, bundle_identifier, license_prefix, and api_key are unique" do
    existing = products(:cozy)
    dup = existing.dup
    assert_not dup.valid?
    assert_includes dup.errors.attribute_names, :slug
    assert_includes dup.errors.attribute_names, :bundle_identifier
    assert_includes dup.errors.attribute_names, :license_prefix
    assert_includes dup.errors.attribute_names, :api_key
  end

  test "update_policy enum" do
    assert products(:cozy).lifetime?
    assert products(:picmal).time_limited?
  end

  test "encrypts loops_api_key and eddsa_private_key at rest" do
    product = products(:cozy)
    ciphertext = Product.connection.select_value(
      "select eddsa_private_key from products where id = '#{product.id}'"
    )
    assert_not_equal "cozy_private_key", ciphertext
    assert_equal "cozy_private_key", product.reload.eddsa_private_key
  end

  test "has many licenses" do
    assert_equal 2, products(:cozy).licenses.count
  end

  test "generates api_key and an Ed25519 keypair on create" do
    product = create_product
    assert product.api_key.present?
    assert product.eddsa_private_key.present?
    assert product.eddsa_public_key.present?
  end

  test "keys are unique across products" do
    a = create_product
    b = create_product
    assert_not_equal a.api_key, b.api_key
    assert_not_equal a.eddsa_private_key, b.eddsa_private_key
    assert_not_equal a.eddsa_public_key, b.eddsa_public_key
  end

  test "private key decrypts to a valid Ed25519 key that derives the public key" do
    product = create_product
    signing = Ed25519::SigningKey.new(Base64.strict_decode64(product.reload.eddsa_private_key))
    derived = Base64.strict_encode64(signing.verify_key.to_bytes)
    assert_equal product.eddsa_public_key, derived
  end

  # If these break, the shutdown plan breaks with them: a rescue token that doesn't verify
  # is discovered on the one day nobody can fix it.
  test "rescue token verifies against the public key the app pins" do
    product = create_product
    head, body, sig = product.rescue_token.split(".")
    verify_key = Ed25519::VerifyKey.new(Base64.strict_decode64(product.eddsa_public_key))
    assert verify_key.verify(Base64.urlsafe_decode64(sig), "#{head}.#{body}")
  end

  test "rescue token fits any machine and never expires in a lifetime" do
    claims = JSON.parse(Base64.urlsafe_decode64(create_product.rescue_token.split(".")[1]))
    assert_equal "*", claims["hardware_id"]
    assert_equal "*", claims["nonce"]
    assert claims["update_eligible"]
    assert_nil claims["expires_at"]
    assert_operator claims["exp"], :>, 50.years.from_now.to_i
  end

  # Existing activation tokens are verified by installs that will never be updated. The
  # header they check has to keep hashing to the same bytes it always did.
  test "sign_jwt without a kid produces the header it always produced" do
    token = create_product.sign_jwt({ hardware_id: "h", nonce: "n" })
    assert_equal "eyJhbGciOiJFZERTQSIsInR5cCI6IkpXVCJ9", token.split(".").first
    assert_equal({ "alg" => "EdDSA", "typ" => "JWT" },
      JSON.parse(Base64.urlsafe_decode64(token.split(".").first)))
  end

  test "sign_jwt with a kid names the key, so a client can pin two of them" do
    product = create_product
    header = JSON.parse(Base64.urlsafe_decode64(product.sign_jwt({ a: 1 }, kid: "b").split(".").first))
    assert_equal({ "alg" => "EdDSA", "typ" => "JWT", "kid" => "b" }, header)
  end

  test "sign_unlock_token signs with the product's current key id" do
    product = create_product
    assert_equal "a", product.eddsa_key_id, "the key already in eddsa_public_key"

    token = product.sign_unlock_token({ v: 1 })
    header, claims, signature = token.split(".")
    assert_equal "a", JSON.parse(Base64.urlsafe_decode64(header))["kid"]

    verify_key = Ed25519::VerifyKey.new(Base64.strict_decode64(product.eddsa_public_key))
    assert verify_key.verify(Base64.urlsafe_decode64(signature), "#{header}.#{claims}")
  end

  test "variants maps Stripe prices, sorts by amount, and reads seats from metadata" do
    list = Struct.new(:data).new([
      fake_price("price_c", "3 seats", 4077, { "seats" => "3" }),
      fake_price("price_a", "1 seat",  1599, { "seats" => "1" }),
      fake_price("price_b", "2 seats", 2878, { "seats" => "2" })
    ])
    Stripe::Price.stub(:list, list) do
      variants = products(:picmal).variants
      assert_equal %w[price_a price_b price_c], variants.map(&:price_id) # amount-sorted
      assert_equal [ 1, 2, 3 ], variants.map(&:seats)
      assert_equal "1 seat", variants.first.name
      assert_equal 1599, variants.first.amount_cents
    end
  end

  # api_key authenticates every desktop client, so a database dump must not hand it over in the
  # clear. Deterministic, or the unique index and Api::BaseController's find_by would break.
  test "api_key is stored encrypted and still resolves a product" do
    product = products(:picmal)
    stored = Product.connection.select_value(
      Product.sanitize_sql([ "SELECT api_key FROM products WHERE id = ?", product.id ]))

    assert_not_equal product.api_key, stored, "api_key is sitting in the clear"
    assert product.api_key.start_with?("prod_"), "it must still decrypt for the app"
    assert_equal product, Product.find_by(api_key: product.api_key)
  end

  # The renewal SKU is a discount for existing owners and the cheapest price on the product —
  # left in, it would headline the storefront and win the cheapest-variant fallback.
  test "variants hides the renewal price from the storefront" do
    product = products(:picmal)
    product.update!(renewal_stripe_price_id: "price_renew")
    list = Struct.new(:data).new([
      fake_price("price_renew", "Renew", 1700, { "seats" => "1" }),
      fake_price("price_full",  "Full",  3500, { "seats" => "1" })
    ])

    Stripe::Price.stub(:list, list) do
      assert_equal [ "price_full" ], product.variants.map(&:price_id)
    end
  end

  test "create_checkout_session refuses the renewal price outside a renewal" do
    product = products(:picmal)
    product.update!(renewal_stripe_price_id: "price_renew")
    price = Struct.new(:id, :product, :metadata)
      .new("price_renew", product.stripe_product_id, { "seats" => "1" })

    Stripe::Price.stub(:retrieve, ->(*_) { price }) do
      assert_raises(Product::CheckoutNotConfigured) do
        product.create_checkout_session(price_id: "price_renew", email: "a@b.com")
      end

      # A key that resolves to nothing is the whole attack: presence alone used to pass, and
      # fulfillment then minted a full license at the discounted price.
      assert_raises(Product::CheckoutNotConfigured) do
        product.create_checkout_session(price_id: "price_renew", email: "a@b.com",
          renew_license_key: "PICM-NOT-A-REAL-KEY")
      end

      Stripe::Checkout::Session.stub(:create, ->(*_) { :session }) do
        assert_equal :session, product.create_checkout_session(price_id: "price_renew",
          email: "a@b.com", renew_license_key: licenses(:picmal_expired).license_key)
      end
    end
  end

  # Upgrade SKUs are pay-the-difference discounts against a license the buyer already owns —
  # on the storefront they'd headline the buy button at $15.
  test "variants hides upgrade prices from the storefront" do
    list = Struct.new(:data).new([
      fake_price("price_up",   "1 to 2", 1500, { "seats" => "2", "upgrade_from_seats" => "1" }),
      fake_price("price_full", "Full",   3900, { "seats" => "2" })
    ])
    Stripe::Price.stub(:list, list) do
      assert_equal [ "price_full" ], products(:picmal).variants.map(&:price_id)
    end
  end

  test "upgrade_variants lists only upgrade prices, with their from-seat gate" do
    list = Struct.new(:data).new([
      fake_price("price_up",   "1 to 2", 1500, { "seats" => "2", "upgrade_from_seats" => "1" }),
      fake_price("price_full", "Full",   3900, { "seats" => "2" })
    ])
    Stripe::Price.stub(:list, list) do
      variants = products(:picmal).upgrade_variants
      assert_equal [ "price_up" ], variants.map(&:price_id)
      assert_equal 1, variants.first.from_seats
      assert_equal 2, variants.first.seats
    end
    assert_equal [], products(:cozy).upgrade_variants, "no Stripe product, no upgrades, no Stripe call"
  end

  test "create_checkout_session refuses an upgrade price without an eligible license" do
    product = products(:picmal)
    price = Struct.new(:id, :product, :metadata)
      .new("price_up", product.stripe_product_id, { "seats" => "5", "upgrade_from_seats" => "2" })

    Stripe::Price.stub(:retrieve, ->(*_) { price }) do
      # No key, junk key, or a license at the wrong seat count — all the same attack as the
      # renewal price: buying a full license at the discounted upgrade rate.
      assert_raises(Product::CheckoutNotConfigured) do
        product.create_checkout_session(price_id: "price_up", email: "a@b.com")
      end
      assert_raises(Product::CheckoutNotConfigured) do
        product.create_checkout_session(price_id: "price_up", email: "a@b.com",
          upgrade_license_key: "PICM-NOT-A-REAL-KEY")
      end
      wrong_seats = product.licenses.create!(status: "active", max_activations: 5)
      assert_raises(Product::CheckoutNotConfigured) do
        product.create_checkout_session(price_id: "price_up", email: "a@b.com",
          upgrade_license_key: wrong_seats.license_key)
      end

      eligible = product.licenses.create!(status: "active", max_activations: 2)
      captured = nil
      Stripe::Checkout::Session.stub(:create, ->(params, *_) { captured = params; :session }) do
        assert_equal :session, product.create_checkout_session(price_id: "price_up",
          email: "a@b.com", upgrade_license_key: eligible.license_key)
      end
      assert_equal eligible.license_key, captured[:metadata][:upgrade_license_key]
    end
  end

  test "variants falls back to max_activations_default when seats metadata is absent" do
    list = Struct.new(:data).new([ fake_price("price_x", "Studio", 12000, {}) ])
    Stripe::Price.stub(:list, list) do
      assert_equal products(:picmal).max_activations_default, products(:picmal).variants.first.seats
    end
  end

  test "seats_for: explicit unlimited, a count, or the product default (H3)" do
    product = products(:picmal) # max_activations_default: 5
    assert_nil product.seats_for(fake_price("p", "n", 100, { "seats" => "unlimited" })), "explicit unlimited"
    assert_nil product.seats_for(fake_price("p", "n", 100, { "seats" => "0" })), "0 = unlimited"
    assert_equal 4, product.seats_for(fake_price("p", "n", 100, { "seats" => "4" }))
    assert_equal 5, product.seats_for(fake_price("p", "n", 100, {})), "blank falls back to the default"
  end

  test "create_checkout_session refuses a price with no seats and no product default (H3)" do
    product = products(:picmal)
    product.update!(max_activations_default: nil)
    price = Struct.new(:id, :product, :metadata).new("price_x", product.stripe_product_id, {})
    Stripe::Price.stub(:retrieve, ->(*_) { price }) do
      assert_raises(Product::CheckoutNotConfigured) do
        product.create_checkout_session(price_id: "price_x", email: "a@b.com")
      end
    end
  end

  test "issue_license! ignores an unrecognized update_policy from price metadata (L1)" do
    license = products(:picmal).issue_license!(customer: customers(:alberto),
      quantity: 1, stripe_payment_id: "pi_l1", update_policy: "bogus")
    assert_nil license.update_policy, "bad enum dropped, not persisted"
    assert_equal "time_limited", license.effective_update_policy, "falls back to the product's policy"
  end

  test "issue_license! records a purchase payment for the intent" do
    license = products(:picmal).issue_license!(customer: customers(:alberto),
      quantity: 1, stripe_payment_id: "pi_pay", amount_cents: 2999, currency: "eur")
    payment = license.payments.sole
    assert payment.kind_purchase?
    assert_equal "pi_pay", payment.stripe_payment_intent
  end

  # Branding is interpolated into an inline style attribute and an <img src> on the portal,
  # so a malformed value has to be rejected at the model rather than reach the page.
  test "branding accepts blank, hex colours and http urls, and rejects anything else" do
    product = create_product
    assert product.valid?, "blank branding should be allowed"

    product.assign_attributes(accent_color: "#2563eb", background_color: "#fff",
      logo_url: "https://example.com/logo.svg")
    assert product.valid?, product.errors.full_messages.to_sentence

    product.accent_color = "red; background: url(evil)"
    assert_not product.valid?
    assert_includes product.errors[:accent_color].to_sentence, "hex colour"

    product.accent_color = "#2563eb"
    product.logo_url = "javascript:alert(1)"
    assert_not product.valid?
    assert_includes product.errors[:logo_url].to_sentence, "http"
  end

  test "brand_style emits only validated colours and nothing for an unbranded product" do
    assert_equal "", create_product.brand_style, "an unbranded product must not override anything"

    branded = create_product
    branded.update!(accent_color: "#2563eb", background_color: "#f9fafb")
    style = branded.brand_style
    assert_includes style, "--color-accent-600: #2563eb"
    assert_includes style, "--color-accent-50: color-mix(in oklab, #2563eb 10%, white)"
    assert_includes style, "--color-accent-800: color-mix(in oklab, #2563eb 68%, black)"
    assert_includes style, "--brand-btn: var(--color-accent-600)"
    assert_includes style, "--brand-bg: #f9fafb"

    # Bypasses validation the way a bad backfill or console edit would.
    branded.update_column(:accent_color, "red;}html{display:none")
    assert_equal "--brand-bg: #f9fafb", branded.brand_style
  end

  test "matching finds a product by slug or display name, any case" do
    product = products(:cozy)
    assert_equal product, Product.matching("cozy").first
    assert_equal product, Product.matching(" Cozy ").first
    assert_equal product, Product.matching(product.name.upcase).first
    assert_nil Product.matching("nobody").first
  end

  private
    def fake_price(id, nickname, unit_amount, metadata)
      # Trailing currency defaults to nil for the callers that don't care.
      Struct.new(:id, :nickname, :unit_amount, :metadata, :currency).new(id, nickname, unit_amount, metadata)
    end

    def create_product
      suffix = SecureRandom.hex(4)
      Product.create!(
        name: "New #{suffix}", slug: "new-#{suffix}",
        bundle_identifier: "com.x.new-#{suffix}",
        license_prefix: "NEW#{suffix}", update_policy: "lifetime"
      )
    end
end
