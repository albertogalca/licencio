require "test_helper"

class Portal::SessionsControllerTest < ActionDispatch::IntegrationTest
  test "a valid token signs in, consumes the token, and lands on the dashboard" do
    token = PortalToken.issue!(customer: customers(:alberto), product: products(:cozy))

    get portal_session_path(token: token.token)
    assert_redirected_to portal_root_path

    follow_redirect!
    assert_response :ok
    assert_nil PortalToken.find_by(id: token.id), "token is single-use and should be destroyed"
  end

  test "the token binds the session to its own product" do
    token = PortalToken.issue!(customer: customers(:alberto), product: products(:cozy))
    get portal_session_path(token: token.token)
    follow_redirect!
    assert_select "h1", /Your Cozy licenses/
  end

  test "an expired token denies access and redirects to recovery" do
    token = PortalToken.issue!(customer: customers(:alberto), product: products(:cozy))
    token.update!(expires_at: 1.minute.ago)

    get portal_session_path(token: token.token)
    assert_redirected_to new_portal_recovery_path

    # No session was established: the dashboard bounces back to recovery.
    get portal_root_path
    assert_redirected_to new_portal_recovery_path
  end

  test "signing out clears the session" do
    token = PortalToken.issue!(customer: customers(:alberto), product: products(:cozy))
    get portal_session_path(token: token.token)

    delete portal_session_path
    assert_redirected_to new_portal_recovery_path(product: "cozy") # logout keeps product context

    get portal_root_path
    assert_redirected_to new_portal_recovery_path # session gone, no product to carry
  end
end
