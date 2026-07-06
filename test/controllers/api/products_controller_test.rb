require "test_helper"

class Api::ProductsControllerTest < ActionDispatch::IntegrationTest
  setup { @product = products(:picmal) }

  test "lists the product's variants from Stripe, cheapest first" do
    list = Struct.new(:data).new([
      fake_price("price_b", "2 seats", 2878, { "seats" => "2" }),
      fake_price("price_a", "1 seat",  1599, { "seats" => "1" })
    ])
    Stripe::Price.stub(:list, list) do
      get "/api/products/#{@product.slug}/variants"
    end
    assert_response :ok
    variants = response.parsed_body["variants"]
    assert_equal %w[price_a price_b], variants.map { |v| v["price_id"] }
    assert_equal({ "price_id" => "price_a", "name" => "1 seat", "amount_cents" => 1599, "seats" => 1 },
      variants.first)
  end

  test "unknown slug is not found" do
    get "/api/products/nope/variants"
    assert_response :not_found
  end

  private
    def fake_price(id, nickname, unit_amount, metadata)
      Struct.new(:id, :nickname, :unit_amount, :metadata).new(id, nickname, unit_amount, metadata)
    end
end
