require "test_helper"

class Portal::UpgradesControllerTest < ActionDispatch::IntegrationTest
  Stub = Struct.new(:id, :product, :metadata, :url, keyword_init: true)
  FakePrice = Struct.new(:id, :nickname, :unit_amount, :currency, :metadata)

  setup do
    @license = licenses(:picmal_expired)
    @license.update!(status: "active", max_activations: 2, expires_at: nil)
    @prices = Struct.new(:data).new([
      FakePrice.new("price_2to5", nil, 3000, "usd", { "seats" => "5", "upgrade_from_seats" => "2" })
    ])
  end

  # Public on purpose: the storefront FAQ links straight here and the key is its own secret.
  test "upgrading needs no sign-in and redirects to Stripe at the license's own upgrade price" do
    captured = nil
    price = Stub.new(id: "price_2to5", product: products(:picmal).stripe_product_id,
      metadata: { "seats" => "5", "upgrade_from_seats" => "2" })
    Stripe::Price.stub(:list, @prices) do
      Stripe::Price.stub(:retrieve, ->(*_) { price }) do
        Stripe::Checkout::Session.stub(:create, ->(params, *_) { captured = params; Stub.new(url: "https://stripe.test/checkout") }) do
          # Client tries to force another price — not among this license's options, so refused.
          post portal_upgrades_path, params: { license_key: @license.license_key, price_id: "price_cheap" }
          assert_redirected_to new_portal_upgrade_path(license_key: @license.license_key)
          assert_nil captured, "an arbitrary price_id must never reach Stripe"

          post portal_upgrades_path, params: { license_key: @license.license_key, price_id: "price_2to5" }
        end
      end
    end

    assert_redirected_to "https://stripe.test/checkout"
    assert_equal "price_2to5", captured[:line_items].first[:price]
    assert_equal @license.license_key, captured[:metadata][:upgrade_license_key]
    assert_equal @license.customer.email, captured[:customer_email], "locks the payer to the license holder"
  end

  test "an upgrade carries the storefront's attribution params into the session" do
    captured = nil
    price = Stub.new(id: "price_2to5", product: products(:picmal).stripe_product_id,
      metadata: { "seats" => "5", "upgrade_from_seats" => "2" })
    Stripe::Price.stub(:list, @prices) do
      Stripe::Price.stub(:retrieve, ->(*_) { price }) do
        Stripe::Checkout::Session.stub(:create, ->(params, *_) { captured = params; Stub.new(url: "https://stripe.test/checkout") }) do
          post portal_upgrades_path, params: { license_key: @license.license_key, price_id: "price_2to5",
            client_reference_id: "visitor_abc", affonso_referral: "aff_1" }
        end
      end
    end

    assert_equal "visitor_abc", captured[:client_reference_id]
    assert_equal "visitor_abc", captured[:metadata][:seline_visitor_id]
    assert_equal "aff_1", captured[:metadata][:affonso_referral]
  end

  test "a license with no matching upgrade SKU never reaches Stripe" do
    called = false
    Stripe::Price.stub(:list, Struct.new(:data).new([])) do
      Stripe::Checkout::Session.stub(:create, ->(*_) { called = true; Stub.new(url: "x") }) do
        post portal_upgrades_path, params: { license_key: @license.license_key, price_id: "price_forged" }
      end
    end

    assert_not called
    assert_redirected_to new_portal_upgrade_path(license_key: @license.license_key)
  end

  test "a bare key submit shows the options instead of charging the first SKU" do
    called = false
    Stripe::Checkout::Session.stub(:create, ->(*_) { called = true; Stub.new(url: "x") }) do
      post portal_upgrades_path, params: { license_key: @license.license_key,
        product: "picmal", client_reference_id: "visitor_abc" }
    end

    assert_not called, "no price was picked, so Stripe must not be reached"
    assert_redirected_to new_portal_upgrade_path(license_key: @license.license_key,
      product: "picmal", client_reference_id: "visitor_abc")
  end

  test "an unknown key is refused without reaching Stripe" do
    called = false
    Stripe::Checkout::Session.stub(:create, ->(*_) { called = true; Stub.new(url: "x") }) do
      post portal_upgrades_path, params: { license_key: "NOPE-0000" }
    end

    assert_not called
    assert_response :redirect
  end

  test "new prefills the key and shows the license's upgrade options with prices" do
    Stripe::Price.stub(:list, @prices) do
      get new_portal_upgrade_path(license_key: @license.license_key,
        client_reference_id: "visitor_abc")
    end

    assert_response :ok
    assert_select "input[name=license_key][value=?]", @license.license_key
    assert_select "input[type=radio][name=price_id][value=price_2to5]"
    assert_match "30.00 USD", @response.body
    # Attribution survives the form POST as hidden fields.
    assert_select "input[type=hidden][name=client_reference_id][value=visitor_abc]"
    assert_select "input[type=hidden][name=affonso_referral]", false, "no empty passenger fields"
  end

  test "new brands off ?product before any key is typed, and the form carries it" do
    get new_portal_upgrade_path(product: "picmal")

    assert_response :ok
    assert_match "your Picmal license", @response.body
    assert_match "PICM-", @response.body, "key placeholder uses the product's prefix"
    assert_select "input[type=hidden][name=product][value=picmal]"
  end

  test "new tells you when a key doesn't exist" do
    get new_portal_upgrade_path(license_key: "NOPE-0000")

    assert_response :ok
    assert_match "We couldn't find that license key", @response.body
  end

  test "new points a license without a self-serve path at support" do
    get new_portal_upgrade_path(license_key: licenses(:cozy_active).license_key)

    assert_response :ok
    assert_match "email support", @response.body
  end
end
