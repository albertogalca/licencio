require "test_helper"

class Admin::LicensesControllerTest < ActionDispatch::IntegrationTest
  test "edit page lists devices with a deactivate control and seat usage" do
    sign_in
    license = licenses(:cozy_active) # has an active + a deactivated activation

    get edit_admin_license_path(license)
    assert_response :ok
    assert_select "h2", /Devices/
    assert_select "*", /seats in use/
    # active device is deactivatable; the deactivated one is not
    assert_select "form[action=?][method=post]", admin_activation_path(activations(:cozy_macbook))
    assert_select "td", /deactivated/
  end

  private
    def sign_in
      post admin_session_path, params: { email: "admin@licencio.example", password: "secret123" }
    end
end
