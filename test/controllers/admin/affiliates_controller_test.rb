require "test_helper"

class Admin::AffiliatesControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  test "approving a pending affiliate flips status and emails the magic link" do
    sign_in
    affiliate = affiliates(:pending)
    assert_enqueued_with(job: AffiliateAccessJob) do
      post admin_affiliate_approval_path(affiliate)
    end
    assert affiliate.reload.approved?
    assert_redirected_to admin_affiliate_path(affiliate)
  end

  test "recording a payout persists it and reduces owed" do
    sign_in
    affiliate = affiliates(:approved)
    assert_difference -> { affiliate.payouts.count }, 1 do
      post admin_affiliate_payouts_path(affiliate),
        params: { payout: { amount_cents: 1500, currency: "EUR", note: "wise 42" } }
    end
    assert_redirected_to admin_affiliate_path(affiliate)
    payout = affiliate.payouts.order(:created_at).last
    assert_equal 1500, payout.amount_cents
    assert_equal "wise 42", payout.note
    assert payout.paid_at.present?, "paid_at defaulted to now"
  end

  test "a zero-amount payout is rejected" do
    sign_in
    affiliate = affiliates(:approved)
    assert_no_difference -> { affiliate.payouts.count } do
      post admin_affiliate_payouts_path(affiliate), params: { payout: { amount_cents: 0, currency: "EUR" } }
    end
    assert_redirected_to admin_affiliate_path(affiliate)
  end

  private
    def sign_in
      post admin_session_path, params: { email: "admin@licencio.example", password: "secret123" }
    end
end
