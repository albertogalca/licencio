require "test_helper"

class Affiliate::SignupsControllerTest < ActionDispatch::IntegrationTest
  test "a valid application creates a pending affiliate and sends nothing" do
    assert_difference "Affiliate.count", 1 do
      assert_no_enqueued_jobs only: AffiliateAccessJob do
        post affiliate_signup_path, params: { affiliate: { name: "New", email: "fresh@example.com", code: "freshcode" } }
      end
    end
    assert_redirected_to new_affiliate_signup_path
    assert Affiliate.find_by(code: "freshcode").pending?
  end

  test "a taken code re-renders the form with errors instead of a false success" do
    assert_no_difference "Affiliate.count" do
      post affiliate_signup_path, params: { affiliate: { name: "Dup", email: "dup@example.com", code: affiliates(:approved).code } }
    end
    assert_response :unprocessable_entity
    assert_select "div", /has already been taken/i
  end
end
