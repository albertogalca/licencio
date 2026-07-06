require "test_helper"

class Api::ActivationsControllerTest < ActionDispatch::IntegrationTest
  # Fixture products carry fake (invalid) Ed25519 keys, so build a real one at runtime.
  setup do
    @product = Product.create!(
      name: "Testy", slug: "testy", bundle_identifier: "com.test.app",
      license_prefix: "TEST", update_policy: "lifetime", max_activations_default: 2
    )
    @license = @product.licenses.create!(status: "active", max_activations: 2)
    @headers = { "X-Api-Key" => @product.api_key }
  end

  def activate(hardware_id:, nonce: "n-123", device_name: "Mac", license_key: @license.license_key)
    post "/api/licenses/activate",
      params: { license_key:, hardware_id:, device_name:, nonce: },
      headers: @headers, as: :json
  end

  test "successful activation returns jwt and public_key" do
    assert_difference "Activation.count", 1 do
      activate(hardware_id: "HW-1")
    end
    assert_response :ok
    body = response.parsed_body
    assert body["jwt"].present?
    assert_equal @product.eddsa_public_key, body["public_key"]
  end

  test "jwt is verifiable with the returned public key and echoes claims" do
    activate(hardware_id: "HW-1", nonce: "abc-nonce")
    jwt = response.parsed_body["jwt"]
    public_key = response.parsed_body["public_key"]

    header_b64, payload_b64, sig_b64 = jwt.split(".")
    verify_key = Ed25519::VerifyKey.new(Base64.strict_decode64(public_key))
    assert verify_key.verify(b64url_decode(sig_b64), "#{header_b64}.#{payload_b64}"),
      "signature must verify with the public key"

    header = JSON.parse(b64url_decode(header_b64))
    claims = JSON.parse(b64url_decode(payload_b64))
    assert_equal "EdDSA", header["alg"]
    assert_equal "HW-1", claims["hardware_id"]
    assert_equal @license.license_key, claims["license_key"]
    assert_equal "abc-nonce", claims["nonce"]
    assert claims["update_eligible"]      # lifetime product
    assert_nil claims["expires_at"]       # no expiry set
    assert claims["iat"].is_a?(Integer)
  end

  test "capacity limit exceeded returns 409" do
    activate(hardware_id: "HW-1")
    activate(hardware_id: "HW-2")
    assert_no_difference "Activation.count" do
      activate(hardware_id: "HW-3")
    end
    assert_response :conflict
  end

  test "re-activating the same device is idempotent" do
    activate(hardware_id: "HW-1")
    assert_no_difference "Activation.count" do
      activate(hardware_id: "HW-1")
    end
    assert_response :ok
  end

  test "deactivation frees the slot" do
    activate(hardware_id: "HW-1")
    activate(hardware_id: "HW-2")

    delete "/api/licenses/deactivate",
      params: { license_key: @license.license_key, hardware_id: "HW-2" },
      headers: @headers, as: :json
    assert_response :no_content

    # Freed slot lets a new device in (would be 409 at capacity otherwise).
    activate(hardware_id: "HW-3")
    assert_response :ok
    assert_equal 2, @license.activations.active.count
  end

  test "deactivating an unknown device returns 404" do
    delete "/api/licenses/deactivate",
      params: { license_key: @license.license_key, hardware_id: "NOPE" },
      headers: @headers, as: :json
    assert_response :not_found
  end

  test "missing or wrong api key is unauthorized" do
    post "/api/licenses/activate",
      params: { license_key: @license.license_key, hardware_id: "HW-1", nonce: "n" }, as: :json
    assert_response :unauthorized

    post "/api/licenses/activate",
      params: { license_key: @license.license_key, hardware_id: "HW-1", nonce: "n" },
      headers: { "X-Api-Key" => "wrong" }, as: :json
    assert_response :unauthorized
  end

  test "unknown license key is 404" do
    activate(hardware_id: "HW-1", license_key: "does-not-exist")
    assert_response :not_found
  end

  test "non-active license is forbidden" do
    @license.update!(status: "expired")
    activate(hardware_id: "HW-1")
    assert_response :forbidden
  end

  test "another product's license is not found" do
    other = Product.create!(
      name: "Other", slug: "other", bundle_identifier: "com.other.app",
      license_prefix: "OTHR", update_policy: "lifetime", max_activations_default: 1
    )
    foreign = other.licenses.create!(status: "active", max_activations: 1)
    activate(hardware_id: "HW-1", license_key: foreign.license_key)
    assert_response :not_found
  end

  test "activation without a license key starts a trial when the product offers one" do
    @product.update!(trial_days: 14)
    assert_difference "License.count", 1 do
      post "/api/licenses/activate", params: { hardware_id: "HW-T", nonce: "n" }, headers: @headers, as: :json
    end
    assert_response :ok
    trial = License.order(:created_at).last
    assert trial.trial?
    assert_in_delta 14.days.from_now.to_i, trial.expires_at.to_i, 1.hour
  end

  test "re-activating a device returns the same trial, never a second one" do
    @product.update!(trial_days: 14)
    post "/api/licenses/activate", params: { hardware_id: "HW-T", nonce: "n" }, headers: @headers, as: :json
    assert_no_difference "License.count" do
      post "/api/licenses/activate", params: { hardware_id: "HW-T", nonce: "n" }, headers: @headers, as: :json
    end
    assert_response :ok
  end

  test "activation without a license key is forbidden when the product has no trial" do
    assert_no_difference "License.count" do
      post "/api/licenses/activate", params: { hardware_id: "HW-T", nonce: "n" }, headers: @headers, as: :json
    end
    assert_response :forbidden
  end

  private
    def b64url_decode(str) = Base64.urlsafe_decode64(str + "=" * ((4 - str.length % 4) % 4))
end
