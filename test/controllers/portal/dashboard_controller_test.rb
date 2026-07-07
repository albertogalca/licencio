require "test_helper"

class Portal::DashboardControllerTest < ActionDispatch::IntegrationTest
  test "requires a signed-in customer" do
    get portal_root_path
    assert_redirected_to new_portal_recovery_path
  end

  test "shows only the signed-in customer's own licenses" do
    sign_in customers(:alberto)

    get portal_root_path
    assert_response :ok
    assert_includes response.body, licenses(:cozy_active).license_key    # alberto's
    assert_not_includes response.body, licenses(:picmal_expired).license_key # nameless's
  end

  private
    def sign_in(customer, product: products(:cozy))
      token = PortalToken.issue!(customer:, product:)
      get portal_session_path(token: token.token)
    end
end
