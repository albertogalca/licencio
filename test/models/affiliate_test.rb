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
