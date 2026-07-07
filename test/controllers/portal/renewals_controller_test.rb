require "test_helper"

class Portal::RenewalsControllerTest < ActionDispatch::IntegrationTest
  Stub = Struct.new(:id, :product, :metadata, :url, keyword_init: true)

  test "renewing redirects to a Stripe checkout at the license's own price, tagged for that license" do
    sign_in customers(:nameless), product: products(:picmal)
    license = licenses(:picmal_expired)
    license.update!(stripe_price_id: "price_orig", max_activations: 5)

    captured = nil
    price = Stub.new(id: "price_orig", product: products(:picmal).stripe_product_id, metadata: { "seats" => "5" })
    Stripe::Price.stub(:retrieve, ->(*_) { price }) do
      Stripe::Checkout::Session.stub(:create, ->(params, *_) { captured = params; Stub.new(url: "https://stripe.test/checkout") }) do
        # Client tries to force a cheaper price — the controller must ignore it.
        post portal_renewals_path, params: { license_id: license.id, price_id: "price_cheap" }
      end
    end

    assert_redirected_to "https://stripe.test/checkout"
    assert_equal "price_orig", captured[:line_items].first[:price], "renews at the license's own price, not the client's"
    assert_equal license.license_key, captured[:metadata][:renew_license_key]
    assert_equal customers(:nameless).email, captured[:customer_email]
  end

  test "cannot renew a license belonging to another customer or product" do
    sign_in customers(:nameless), product: products(:picmal)
    foreign = licenses(:cozy_active) # alberto's, and a different product

    called = false
    Stripe::Checkout::Session.stub(:create, ->(*_) { called = true; Stub.new(url: "x") }) do
      post portal_renewals_path, params: { license_id: foreign.id, price_id: "price_x" }
    end

    assert_redirected_to portal_root_path
    assert_not called, "must not reach Stripe for a scoped-out license"
  end

  test "unauthenticated renewal is redirected to recovery" do
    post portal_renewals_path, params: { license_id: licenses(:picmal_expired).id, price_id: "price_x" }
    assert_response :redirect
    assert_match "recover", @response.location
  end

  private
    def sign_in(customer, product:)
      token = PortalToken.issue!(customer:, product:)
      get portal_session_path(token: token.token)
    end
end
