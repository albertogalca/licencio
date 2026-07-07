require "test_helper"

class LicenseEmailJobTest < ActiveJob::TestCase
  test "resolves the product's template attribute and sends base variables" do
    license  = licenses(:cozy_active)
    customer = license.customer
    product  = license.product
    product.update!(purchase_transactional_id: "tx_purchase")
    token = PortalToken.issue!(customer:, product:)

    captured = nil
    Loops.stub(:send_transactional, ->(**kwargs) { captured = kwargs }) do
      LicenseEmailJob.perform_now(token, template: :purchase_transactional_id,
        kind: "purchase", reference_id: license.id, data: { amount: "29.99 EUR" })
    end

    assert_equal "tx_purchase", captured[:transactional_id]
    assert_equal customer.email, captured[:email]
    assert_equal product.name, captured[:data][:product_name]
    assert_includes captured[:data][:license_keys], license.license_key
    assert_includes captured[:data][:magic_link_url], token.token
    assert_equal "29.99 EUR", captured[:data][:amount] # override merged in
  end

  test "data overrides base variables (expiry sends one key + expires_at)" do
    license = licenses(:cozy_active)
    product = license.product
    product.update!(expiry_reminder_transactional_id: "tx_expiry")
    token = PortalToken.issue!(customer: license.customer, product:)

    captured = nil
    Loops.stub(:send_transactional, ->(**kwargs) { captured = kwargs }) do
      LicenseEmailJob.perform_now(token, template: :expiry_reminder_transactional_id,
        kind: "expiry", reference_id: license.id,
        data: { license_keys: "ONLY-THIS-KEY", expires_at: "2026-12-31" })
    end

    assert_equal "ONLY-THIS-KEY", captured[:data][:license_keys]
    assert_equal "2026-12-31", captured[:data][:expires_at]
  end

  test "a re-run for the same (customer, kind, reference) sends only once" do
    license = licenses(:cozy_active)
    license.product.update!(purchase_transactional_id: "tx_purchase")
    token = PortalToken.issue!(customer: license.customer, product: license.product)

    sends = 0
    Loops.stub(:send_transactional, ->(**) { sends += 1 }) do
      2.times do
        LicenseEmailJob.perform_now(token, template: :purchase_transactional_id,
          kind: "purchase", reference_id: license.id)
      end
    end
    assert_equal 1, sends, "the second delivery is suppressed by Notification.once"
  end

  test "does nothing when the product has no template for that attribute" do
    product = products(:cozy)
    product.update!(refund_transactional_id: nil)
    token = PortalToken.issue!(customer: customers(:alberto), product:)

    called = false
    Loops.stub(:send_transactional, ->(**) { called = true }) do
      LicenseEmailJob.perform_now(token, template: :refund_transactional_id,
        kind: "refund", reference_id: licenses(:cozy_active).id)
    end
    assert_not called
  end
end
