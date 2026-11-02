require "test_helper"

class Admin::RedemptionCodesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @codes = RedemptionCode.generate!(product: products(:picmal), count: 3)
    @redeemed = RedemptionCode.redeem!(@codes.first, email: "buyer@example.com")
    sign_in
  end

  test "shows pool stats and lists codes in use" do
    get admin_redemption_codes_path
    assert_response :ok
    assert_select "p", /2\s+unredeemed\s+·\s+1\s+redeemed/
    assert_select "td", /buyer@example.com/
  end

  test "searches by full code and by email" do
    get admin_redemption_codes_path(q: @codes.second)
    assert_select "tbody tr", 1
    assert_select "td", /unredeemed/

    get admin_redemption_codes_path(q: "buyer@")
    assert_select "tbody tr", 1
    assert_select "td", /buyer@example.com/
  end

  test "revoke takes back the seat" do
    post revoke_admin_redemption_code_path(@redeemed)
    assert_redirected_to admin_redemption_codes_path
    assert @redeemed.reload.revoked?
    assert @redeemed.license.reload.inactive?
  end

  private
    def sign_in
      post admin_session_path, params: { email: "admin@licencio.example", password: "secret123" }
    end
end
