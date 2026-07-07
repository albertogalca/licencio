require "test_helper"

class Admin::LicensesControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  test "creating a license for a customer emails them their access" do
    sign_in
    assert_enqueued_with(job: PortalAccessJob) do
      post admin_licenses_path, params: { license: {
        product_id: products(:cozy).id, customer_email: "buyer@example.com",
        max_activations: 3, status: "active" } }
    end
    assert_redirected_to admin_licenses_path
    assert_match(/access email sent/, flash[:notice])
  end

  test "edit page lists devices with a deactivate control and seat usage" do
    sign_in
    license = licenses(:cozy_active) # has an active + a deactivated activation

    get edit_admin_license_path(license)
    assert_response :ok
    assert_select "h2", /Devices/
    assert_select "*", /seats in use/
    # active device is deactivatable; the deactivated one is not
    assert_select "form[action=?][method=post]", admin_activation_path(activations(:cozy_macbook))
    assert_select "span", /deactivated/
  end

  private
    def sign_in
      post admin_session_path, params: { email: "admin@licencio.example", password: "secret123" }
    end
end
