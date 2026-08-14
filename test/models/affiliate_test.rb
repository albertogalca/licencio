require "test_helper"

class AffiliateTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @affiliate = affiliates(:approved)
    @product = products(:picmal)
  end

  test "commission_for is a whole-percent cut, floored" do
    assert_equal 600, @affiliate.commission_for(3000) # 20%
    assert_equal 199, @affiliate.commission_for(999)  # floored
  end

  test "commission_percent_for prefers the product override, falls back to the affiliate rate" do
    @product.update!(affiliate_commission_percent: 25)
    assert_equal 25, @affiliate.commission_percent_for(@product)

    @product.update!(affiliate_commission_percent: nil)
    assert_equal @affiliate.commission_percent, @affiliate.commission_percent_for(@product)
  end

  test "code is normalized to lowercase" do
    a = Affiliate.create!(code: "MixedCase", name: "X", email: "x@example.com")
    assert_equal "mixedcase", a.code
  end

  test "approve! flips status and enqueues the magic-link email" do
    a = affiliates(:pending)
    assert_enqueued_with(job: AffiliateAccessJob) { a.approve! }
    assert a.reload.approved?
  end

  test "a pending affiliate is not sent a dashboard link" do
    assert_no_enqueued_jobs only: AffiliateAccessJob do
      affiliates(:pending).send_dashboard_access_later
    end
  end

  test "self_referral? matches either of the affiliate's own addresses, normalized" do
    assert @affiliate.self_referral?(@affiliate.email)
    assert @affiliate.self_referral?(@affiliate.payout_email)
    assert @affiliate.self_referral?(" AFF-Alberto+ref@Example.com "), "+tags and case must not dodge it"
    assert_not @affiliate.self_referral?("someone-else@example.com")
    assert_not @affiliate.self_referral?(nil)
  end

  test "a reserved code cannot be squatted through public signup" do
    squatter = Affiliate.new(name: "S", email: "s@example.com", code: "picmal", commission_percent: 20)
    assert_not squatter.valid?
    assert_includes squatter.errors[:code], "is reserved"
  end

  test "a payout cannot exceed what is owed" do
    license = @product.licenses.create!(status: "active", max_activations: 1)
    license.payments.create!(stripe_payment_intent: "pi_owed", kind: "purchase",
      affiliate: @affiliate, commission_cents: 700, created_at: 40.days.ago)

    too_much = @affiliate.payouts.new(amount_cents: 900, currency: "eur", paid_at: Time.current)
    assert_not too_much.valid?
    assert_includes too_much.errors[:amount_cents], "is more than the 700 cents currently owed"

    assert @affiliate.payouts.create!(amount_cents: 700, currency: "eur", paid_at: Time.current)
    duplicate = @affiliate.payouts.new(amount_cents: 700, currency: "eur", paid_at: Time.current)
    assert_not duplicate.valid?, "a double-clicked form must not pay twice"
  end

  test "payable excludes sales inside the 30-day hold and refunded licenses" do
    license = @product.licenses.create!(status: "active", max_activations: 1)
    fresh = license.payments.create!(stripe_payment_intent: "pi_fresh", kind: "purchase",
      affiliate: @affiliate, commission_cents: 500)
    old = license.payments.create!(stripe_payment_intent: "pi_old", kind: "purchase",
      affiliate: @affiliate, commission_cents: 700, created_at: 40.days.ago)

    assert_includes Payment.payable, old
    assert_not_includes Payment.payable, fresh, "still inside the 30-day hold"

    license.update!(status: "refunded")
    assert_not_includes Payment.payable, old, "refunded license drops out"
  end
end
