require "test_helper"

class Portal::RenewalsControllerTest < ActionDispatch::IntegrationTest
  Stub = Struct.new(:id, :product, :metadata, :url, keyword_init: true)

  # Public on purpose: a reminder email read three days later outlives its 30-minute magic link,
  # and the key is its own secret.
  test "renewing needs no sign-in and redirects to Stripe at the license's own price" do
    license = licenses(:picmal_expired)
    license.update!(stripe_price_id: "price_orig", max_activations: 5)

    captured = nil
    price = Stub.new(id: "price_orig", product: products(:picmal).stripe_product_id, metadata: { "seats" => "5" })
    Stripe::Price.stub(:retrieve, ->(*_) { price }) do
      Stripe::Checkout::Session.stub(:create, ->(params, *_) { captured = params; Stub.new(url: "https://stripe.test/checkout") }) do
        # Client tries to force a cheaper price — the controller must ignore it.
        post portal_renewals_path, params: { license_key: license.license_key, price_id: "price_cheap" }
      end
    end

    assert_redirected_to "https://stripe.test/checkout"
    assert_equal "price_orig", captured[:line_items].first[:price], "renews at the license's own price, not the client's"
    assert_equal license.license_key, captured[:metadata][:renew_license_key]
    assert_equal license.customer.email, captured[:customer_email], "locks the payer to the license holder"
  end

  test "the product's renewal price wins over what the license originally paid" do
    license = licenses(:picmal_expired)
    license.update!(stripe_price_id: "price_orig", max_activations: 5)
    products(:picmal).update!(renewal_stripe_price_id: "price_renew")

    captured = nil
    price = Stub.new(id: "price_renew", product: products(:picmal).stripe_product_id, metadata: { "seats" => "5" })
    Stripe::Price.stub(:retrieve, ->(*_) { price }) do
      Stripe::Checkout::Session.stub(:create, ->(params, *_) { captured = params; Stub.new(url: "https://stripe.test/checkout") }) do
        post portal_renewals_path, params: { license_key: license.license_key }
      end
    end

    assert_equal "price_renew", captured[:line_items].first[:price]
  end

  test "a renewal carries the storefront's attribution params into the session" do
    license = licenses(:picmal_expired)
    license.update!(stripe_price_id: "price_orig", max_activations: 5)

    captured = nil
    price = Stub.new(id: "price_orig", product: products(:picmal).stripe_product_id, metadata: { "seats" => "5" })
    Stripe::Price.stub(:retrieve, ->(*_) { price }) do
      Stripe::Checkout::Session.stub(:create, ->(params, *_) { captured = params; Stub.new(url: "https://stripe.test/checkout") }) do
        post portal_renewals_path, params: { license_key: license.license_key,
          client_reference_id: "visitor_abc", affonso_referral: "aff_1" }
      end
    end

    assert_equal "visitor_abc", captured[:client_reference_id]
    assert_equal "visitor_abc", captured[:metadata][:seline_visitor_id],
      "Seline matches a guest charge only on this key"
    assert_equal "aff_1", captured[:metadata][:affonso_referral]
  end

  test "an attribution param too long for Stripe is dropped, not sent" do
    license = licenses(:picmal_expired)
    license.update!(stripe_price_id: "price_orig", max_activations: 5)

    captured = nil
    price = Stub.new(id: "price_orig", product: products(:picmal).stripe_product_id, metadata: { "seats" => "5" })
    Stripe::Price.stub(:retrieve, ->(*_) { price }) do
      Stripe::Checkout::Session.stub(:create, ->(params, *_) { captured = params; Stub.new(url: "https://stripe.test/checkout") }) do
        post portal_renewals_path, params: { license_key: license.license_key,
          client_reference_id: "x" * 201 }
      end
    end

    assert_redirected_to "https://stripe.test/checkout", "the renewal still goes through"
    assert_nil captured[:client_reference_id]
    assert_nil captured[:metadata][:seline_visitor_id]
  end

  test "new carries the attribution params across the form as hidden fields" do
    license = licenses(:picmal_expired)

    get new_portal_renewal_path(license_key: license.license_key,
      client_reference_id: "visitor_abc")

    # The POST is where they'd silently vanish, and the buyer never sees this page's source.
    assert_select "input[type=hidden][name=client_reference_id][value=visitor_abc]"
    assert_select "input[type=hidden][name=affonso_referral]", false, "no empty passenger fields"
  end

  test "a license that can't be renewed never reaches Stripe" do
    lifetime = licenses(:cozy_active) # no expires_at, lifetime product

    called = false
    Stripe::Checkout::Session.stub(:create, ->(*_) { called = true; Stub.new(url: "x") }) do
      post portal_renewals_path, params: { license_key: lifetime.license_key }
    end

    assert_not called, "must not reach Stripe for a license with nothing to renew"
    assert_redirected_to new_portal_renewal_path(license_key: lifetime.license_key)
  end

  test "an unknown key is refused without reaching Stripe" do
    called = false
    Stripe::Checkout::Session.stub(:create, ->(*_) { called = true; Stub.new(url: "x") }) do
      post portal_renewals_path, params: { license_key: "NOPE-0000" }
    end

    assert_not called
    assert_response :redirect
  end

  test "new prefills the key from the link and shows when updates ended" do
    license = licenses(:picmal_expired)

    get new_portal_renewal_path(license_key: license.license_key)

    assert_response :ok
    assert_select "input[name=license_key][value=?]", license.license_key
    assert_match "Updates ended", @response.body
  end

  test "new with no key just asks for one" do
    get new_portal_renewal_path

    assert_response :ok
    assert_select "input[name=license_key]"
    assert_no_match "couldn't find", @response.body
  end

  test "new tells you when a key doesn't exist" do
    get new_portal_renewal_path(license_key: "NOPE-0000")

    assert_response :ok
    assert_match "We couldn't find that license key", @response.body
  end
end
