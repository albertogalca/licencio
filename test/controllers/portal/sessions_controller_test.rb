require "test_helper"

class Portal::SessionsControllerTest < ActionDispatch::IntegrationTest
  test "a valid token signs in, clears the token, and lands on the dashboard" do
    customer = customers(:alberto)
    customer.update!(auth_token: "valid-token", auth_token_expires_at: 10.minutes.from_now)

    get portal_session_path(token: "valid-token")
    assert_redirected_to portal_root_path

    follow_redirect!
    assert_response :ok
    assert_nil customer.reload.auth_token, "token is single-use and should be cleared"
  end

  test "an expired token denies access and redirects to recovery" do
    customers(:alberto).update!(auth_token: "stale", auth_token_expires_at: 1.minute.ago)

    get portal_session_path(token: "stale")
    assert_redirected_to new_portal_recovery_path

    # No session was established: the dashboard bounces back to recovery.
    get portal_root_path
    assert_redirected_to new_portal_recovery_path
  end

  test "signing out clears the session" do
    customer = customers(:alberto)
    customer.update!(auth_token: "t", auth_token_expires_at: 10.minutes.from_now)
    get portal_session_path(token: "t")

    delete portal_session_path
    assert_redirected_to new_portal_recovery_path

    get portal_root_path
    assert_redirected_to new_portal_recovery_path
  end
end
