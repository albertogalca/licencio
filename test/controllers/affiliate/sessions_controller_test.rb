require "test_helper"

class Affiliate::SessionsControllerTest < ActionDispatch::IntegrationTest
  setup { @affiliate = affiliates(:approved) }

  test "a valid magic link signs the affiliate in" do
    token = AffiliateToken.issue!(affiliate: @affiliate)
    get affiliate_session_path(token: token.token)
    assert_redirected_to affiliate_root_path
    follow_redirect!
    assert_response :success
  end

  test "an expired token is rejected and the session is not set" do
    token = AffiliateToken.issue!(affiliate: @affiliate)
    token.update!(expires_at: 1.minute.ago)
    get affiliate_session_path(token: token.token)
    assert_redirected_to new_affiliate_recovery_path
    get affiliate_root_path
    assert_redirected_to new_affiliate_recovery_path, "not authenticated"
  end
end
