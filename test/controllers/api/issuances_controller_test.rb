require "test_helper"

class Api::IssuancesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @product = Product.create!(name: "Testy", slug: "testy", bundle_identifier: "com.test.app",
      license_prefix: "TEST", update_policy: "lifetime", max_activations_default: 2)
    @headers = { "X-Api-Key" => @product.rotate_issuance_api_key! }
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

  test "seats up to the ceiling are accepted" do
    issue(seats: Product::MAX_ISSUED_SEATS)
    assert_response :ok
    assert_equal Product::MAX_ISSUED_SEATS, @product.licenses.sole.max_activations
  end

  # Base 10: Ruby's literal rules would read a leading zero as octal and hand over 8 seats.
  test "a leading zero is still base 10" do
    issue(seats: "010")
    assert_response :ok
    assert_equal 10, @product.licenses.sole.max_activations
  end

  test "refuses seats above the ceiling, below one, or not a number" do
    [ Product::MAX_ISSUED_SEATS + 1, 1_000_000, 0, -3, "lots", "0x0A", "0b11", "2.5" ].each do |seats|
      assert_no_difference [ "License.count", "Customer.count" ], "seats=#{seats.inspect}" do
        issue(seats:)
      end
      assert_response :unprocessable_entity
      assert_equal "invalid_seats", response.parsed_body["code"]
    end
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

  # The client key ships inside every desktop build, so it is public. It must never mint.
  test "rejects the product's client api key" do
    assert_no_difference "License.count" do
      issue(headers: { "X-Api-Key" => @product.api_key })
    end
    assert_response :unauthorized
    assert_equal "unauthorized", response.parsed_body["code"]
  end

  test "a product with no issuance key cannot issue at all" do
    @product.update!(issuance_api_key: nil)

    assert_no_difference "License.count" do
      issue(headers: { "X-Api-Key" => "" })
      issue(headers: { "X-Api-Key" => @product.api_key })
    end
    assert_response :unauthorized
  end

  test "a rotated issuance key stops working" do
    old_key = @headers["X-Api-Key"]
    @product.rotate_issuance_api_key!

    assert_no_difference "License.count" do
      issue(headers: { "X-Api-Key" => old_key })
    end
    assert_response :unauthorized
  end

  test "the issuance key does not open the client endpoints" do
    license = @product.licenses.create!(status: "active", max_activations: 2)

    post "/api/licenses/activate", headers: @headers, as: :json,
      params: { license_key: license.license_key, hardware_id: "HW-1", device_name: "Mac", nonce: "n" }

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
