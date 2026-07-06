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
    def sign_in(customer)
      customer.update!(auth_token: "tok-#{customer.id}", auth_token_expires_at: 10.minutes.from_now)
      get portal_session_path(token: customer.auth_token, product: "cozy")
    end
end
