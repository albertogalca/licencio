require "test_helper"

class Api::ValidationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @product = products(:picmal) # time_limited/365
    @license = licenses(:picmal_expired)
  end

  def validate(license_key: @license.license_key, product_slug: @product.slug)
    post "/api/licenses/validate", params: { license_key:, product_slug: }, as: :json
  end

  # The whole reason this endpoint exists: an App Store binary can't carry the product API
  # key, because anyone who unzips the .ipa could then mint licenses and trials.
  test "validates with no API key at all" do
    @license.update!(status: "active", expires_at: 1.year.from_now)

    validate

    assert_response :ok
    assert_equal true, response.parsed_body["valid"]
    assert_equal "annual", response.parsed_body["tier"]
    assert_equal true, response.parsed_body["update_eligible"]
    assert_equal @license.reload.expires_at.iso8601, response.parsed_body["expires_at"]
  end

  # A lapsed update window still owns the app — that's the annual promise, and mobile is
  # a purchase they already made.
  test "a lapsed license still unlocks, reporting update_eligible false" do
    validate # fixture is expired

    assert_response :ok
    assert_equal true, response.parsed_body["valid"]
    assert_equal false, response.parsed_body["update_eligible"]
  end

  test "creates no activation and consumes no seat" do
    assert_no_difference "Activation.count" do
      validate
    end
  end

  test "a refunded license is refused" do
    @license.update!(status: "refunded")

    validate

    assert_response :forbidden
    assert_equal "license_refunded", response.parsed_body["code"]
  end

  # Seven days must not buy a permanent unlock.
  test "a trial is refused, and not as 'inactive' — it's live, just not an entitlement" do
    trial = @product.licenses.create!(status: "active", trial: true, max_activations: 1,
      expires_at: 7.days.from_now)

    validate(license_key: trial.license_key)

    assert_response :forbidden
    assert_equal "license_not_eligible", response.parsed_body["code"]
  end

  test "a key from another product does not unlock this one" do
    validate(license_key: licenses(:cozy_active).license_key)

    assert_response :not_found
    assert_equal "license_not_found", response.parsed_body["code"]
  end

  test "an unknown key and an unknown product both 404" do
    validate(license_key: "NOPE-0000")
    assert_response :not_found

    validate(product_slug: "nope")
    assert_response :not_found
  end

  test "surrounding whitespace from a paste is tolerated" do
    validate(license_key: "  #{@license.license_key}\n")

    assert_response :ok
    assert_equal true, response.parsed_body["valid"]
  end

  # Cozy for iOS posts from capacitor://localhost. JSON isn't a CORS-safelisted content type,
  # so WKWebView sends OPTIONS first and refuses to hand the app a response that doesn't
  # allow the origin. Without these the unlock screen only ever says "Couldn't connect".
  test "the preflight is answered and allows the origin" do
    process :options, "/api/licenses/validate",
      headers: { "Origin" => "capacitor://localhost",
                 "Access-Control-Request-Method" => "POST",
                 "Access-Control-Request-Headers" => "content-type" }

    assert_response :no_content
    assert_equal "*", response.headers["Access-Control-Allow-Origin"]
    assert_includes response.headers["Access-Control-Allow-Headers"], "Content-Type"
  end

  # The preflight is only half of it — the browser also checks the real response.
  test "the POST response allows the origin too, success or failure" do
    validate
    assert_response :ok
    assert_equal "*", response.headers["Access-Control-Allow-Origin"]

    validate(license_key: "NOPE-0000")
    assert_response :not_found
    assert_equal "*", response.headers["Access-Control-Allow-Origin"]
  end

  # No test covers `only: :create` on the rate limit — the test env runs :null_store, and
  # rate_limit binds ActionController::Base.cache_store when the class body loads, so it
  # can't be armed from in here. Nothing else in this repo tests rate limiting either.
end
