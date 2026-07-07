require "test_helper"

class Portal::SessionsControllerTest < ActionDispatch::IntegrationTest
  test "a valid token signs in, lands on the dashboard, and stays reusable within its window" do
    token = PortalToken.issue!(customer: customers(:alberto), product: products(:cozy))

    get portal_session_path(token: token.token)
    assert_redirected_to portal_root_path

    follow_redirect!
    assert_response :ok
    assert PortalToken.find_by(id: token.id), "token is reusable within its 30-minute window"

    # Reopening the same link (e.g. a fresh browser) still works until it expires.
    reset!
    get portal_session_path(token: token.token)
    assert_redirected_to portal_root_path
  end

  test "the token binds the session to its own product" do
    token = PortalToken.issue!(customer: customers(:alberto), product: products(:cozy))
    get portal_session_path(token: token.token)
    follow_redirect!
    assert_select "h1", /Your Cozy licenses/
  end

  test "an expired token denies access and recovers to the link's product" do
    token = PortalToken.issue!(customer: customers(:alberto), product: products(:cozy))
    token.update!(expires_at: 1.minute.ago)

    # The email link carries ?product=cozy, so an expired link lands on cozy's recovery form.
    get portal_session_path(token: token.token, product: "cozy")
    assert_redirected_to new_portal_recovery_path(product: "cozy")

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
