require "test_helper"

class Product::AppStoreTrialableTest < ActiveSupport::TestCase
  NOW = Time.utc(2026, 10, 14, 12)

  setup do
    @product = Product.order(:slug).first
    @product.update!(trial_days: 7)
  end

  def charge(at, buyer:, amount_cents:, environment: "production", revoked_at: nil)
    @product.app_store_charges.create!(transaction_id: SecureRandom.hex(8), original_transaction_id: SecureRandom.hex(8),
      store_product_id: amount_cents.zero? ? "com.example.myapp.trial" : "com.example.myapp.unlock",
      app_transaction_id: buyer, environment:, purchased_at: at, amount_cents:, revoked_at:)
  end

  def trial(at, buyer:, **) = charge(at, buyer:, amount_cents: 0, **)
  def unlock(at, buyer:, **) = charge(at, buyer:, amount_cents: 1999, **)

  def report = @product.app_store_trial_report(now: NOW)

  test "the same buyer's first paid purchase after the trial started converts it" do
    trial Time.utc(2026, 10, 1, 12), buyer: "A"
    unlock Time.utc(2026, 10, 3, 12), buyer: "A"
    unlock Time.utc(2026, 10, 9, 12), buyer: "A"
    trial Time.utc(2026, 10, 2, 12), buyer: "B"
    unlock Time.utc(2026, 10, 4, 12), buyer: "C"
    trial Time.utc(2026, 10, 13, 12), buyer: "D"

    assert_equal [ 3, 1, 1, 2.0 ], report.total.to_h.values_at(:started, :running, :converted, :median_days)
    assert_equal [ [ Date.new(2026, 10, 12), 1, 0 ], [ Date.new(2026, 9, 28), 2, 1 ] ],
      report.weeks.map { [ _1.week, _1.started, _1.converted ] }
    assert_equal 0, report.unlinked
  end

  test "a purchase from before the trial started does not convert it" do
    unlock Time.utc(2026, 9, 30, 12), buyer: "A"
    trial Time.utc(2026, 10, 1, 12), buyer: "A"

    assert_equal [ 1, 0 ], [ report.total.started, report.total.converted ]
  end

  test "a refunded purchase does not convert the trial" do
    trial Time.utc(2026, 10, 1, 12), buyer: "A"
    unlock Time.utc(2026, 10, 3, 12), buyer: "A", revoked_at: Time.utc(2026, 10, 5)

    assert_equal [ 1, 0 ], [ report.total.started, report.total.converted ]
  end

  test "sandbox purchases neither start a trial nor convert one" do
    trial Time.utc(2026, 10, 1, 12), buyer: "A"
    unlock Time.utc(2026, 10, 3, 12), buyer: "A", environment: "sandbox"
    trial Time.utc(2026, 10, 2, 12), buyer: "B", environment: "sandbox"

    assert_equal [ 1, 0 ], [ report.total.started, report.total.converted ]
  end

  test "a trial without an app transaction id is never bought and is counted as unlinked" do
    trial Time.utc(2026, 10, 1, 12), buyer: nil
    unlock Time.utc(2026, 10, 3, 12), buyer: nil
    trial Time.utc(2026, 10, 2, 12), buyer: "A"

    assert_equal [ 2, 0 ], [ report.total.started, report.total.converted ]
    assert_equal 1, report.unlinked
  end

  test "trials from before the window are left out" do
    trial Time.utc(2026, 8, 1, 12), buyer: nil

    assert_predicate report, :empty?
    assert_equal 0, report.unlinked
  end

  test "a product without trial_days has an empty report" do
    trial Time.utc(2026, 10, 1, 12), buyer: "A"
    @product.update!(trial_days: nil)

    assert_predicate report, :empty?
    assert_equal 0, report.unlinked
  end
end
