require "test_helper"

class Admin::EmailsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  test "an admin resends the access link and lands back on the license page" do
    sign_in
    license = licenses(:cozy_active)
    assert_enqueued_with(job: PortalAccessJob) do
      post admin_license_emails_path(license), params: { kind: "portal" }
    end
    assert_redirected_to edit_admin_license_path(license)
    assert_match(/Access link email queued/, flash[:notice])
  end

  test "resending an inapplicable email reports it can't be sent" do
    sign_in
    license = licenses(:cozy_active) # not refunded
    assert_no_enqueued_jobs do
      post admin_license_emails_path(license), params: { kind: "refund" }
    end
    assert_redirected_to edit_admin_license_path(license)
    assert_match(/can't be sent/, flash[:alert])
  end

  test "an unauthenticated request is bounced to the admin login" do
    assert_no_enqueued_jobs do
      post admin_license_emails_path(licenses(:cozy_active)), params: { kind: "portal" }
    end
    assert_redirected_to new_admin_session_path
  end

  private
    def sign_in
      post admin_session_path, params: { email: "admin@licencio.example", password: "secret123" }
    end
end
