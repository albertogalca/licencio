require "test_helper"

class Api::Admin::RedemptionCodesControllerTest < ActionDispatch::IntegrationTest
  setup do
    ENV["ADMIN_API_KEY"] = "admin-secret"
    @code = RedemptionCode.generate!(product: products(:picmal), count: 1).first
  end

  test "revokes a code by its plaintext and takes back its seat" do
    license = RedemptionCode.redeem!(@code, email: "refund@example.com").license

    post "/api/admin/redemption_codes/revoke", params: { code: @code },
      headers: { "Authorization" => "Bearer admin-secret" }, as: :json

    assert_response :ok
    assert_equal "revoked", response.parsed_body["status"]
    assert_equal 0, license.reload.max_activations
    assert license.inactive?
  end

  test "an unknown code is a 404 and a missing key is a 401" do
    post "/api/admin/redemption_codes/revoke", params: { code: "NOPE" },
      headers: { "Authorization" => "Bearer admin-secret" }, as: :json
    assert_response :not_found

    post "/api/admin/redemption_codes/revoke", params: { code: @code }, as: :json
    assert_response :unauthorized
    assert RedemptionCode.find_by_code(@code).unredeemed?
  end
end
