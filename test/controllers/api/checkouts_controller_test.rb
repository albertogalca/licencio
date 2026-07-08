require "test_helper"

class Api::CheckoutsControllerTest < ActionDispatch::IntegrationTest
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

  test "GET redirects the buyer straight to Stripe Checkout and forwards client_reference_id" do
    price = fake_price("price_3", @product.stripe_product_id, { "seats" => "3" })
    captured = nil
    Stripe::Price.stub(:retrieve, price) do
      Stripe::Checkout::Session.stub(:create, ->(params, _opts = {}) { captured = params; fake_session }) do
        get "/api/checkout", params: { product_slug: @product.slug, price_id: "price_3", client_reference_id: "ph_abc" }
      end
    end

    assert_redirected_to "https://stripe.test/session"
    assert_equal "ph_abc", captured[:client_reference_id]
  end

  test "rejects a price that belongs to a different Stripe product" do
    price = fake_price("price_x", "prod_someone_else", { "seats" => "1" })
    Stripe::Price.stub(:retrieve, price) do
      post "/api/checkout", params: { product_slug: @product.slug, price_id: "price_x" }
    end
    assert_response :not_found
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
