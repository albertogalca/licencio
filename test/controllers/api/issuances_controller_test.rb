require "test_helper"

class Api::IssuancesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @product = Product.create!(name: "Testy", slug: "testy", bundle_identifier: "com.test.app",
      license_prefix: "TEST", update_policy: "lifetime", max_activations_default: 2)
    @headers = { "X-Api-Key" => @product.api_key }
  end

  def issue(headers: @headers, **params)
    post "/api/licenses/issue",
      params: { email: "ada@example.com", name: "Ada", order: "BH-1" }.merge(params),
      headers:, as: :json
  end

  test "mints an active license and answers with the bare key" do
    assert_difference "License.count", 1 do
      issue
    end
    assert_response :ok

    license = @product.licenses.sole
    assert_equal license.license_key, response.body
    assert_equal "text/plain", response.media_type
    assert_equal "active", license.status
    assert_equal 2, license.max_activations
    assert_equal "ada@example.com", license.customer.email
  end

  test "seats param overrides the product default" do
    issue(seats: 5)
    assert_equal 5, @product.licenses.sole.max_activations
  end

  test "repeats mint separate keys — one order number covers several licenses" do
    assert_difference "License.count", 2 do
      2.times { issue }
    end
    assert_equal 2, Customer.find_by(email: "ada@example.com").licenses.count
  end

  # How the bundle store is wired: it can only map customer fields to parameters, so the seat
  # count rides on the endpoint URL's query string instead.
  test "seats can arrive on the query string, with no product default set" do
    @product.update!(max_activations_default: nil)

    post "/api/licenses/issue?seats=2",
      params: { email: "ada@example.com", name: "Ada" }, headers: @headers, as: :json

    assert_response :ok
    assert_equal 2, @product.licenses.sole.max_activations
  end

  test "rejects a bad address without minting" do
    assert_no_difference "License.count" do
      issue(email: "not-an-email")
    end
    assert_response :unprocessable_entity
  end

  test "rejects a missing api key" do
    assert_no_difference "License.count" do
      issue(headers: {})
    end
    assert_response :unauthorized
  end

  test "refuses rather than minting an unlimited-seat license" do
    @product.update!(max_activations_default: nil)
    assert_no_difference "License.count" do
      issue
    end
    assert_response :service_unavailable
  end
end
