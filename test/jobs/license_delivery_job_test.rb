require "test_helper"

class LicenseDeliveryJobTest < ActiveJob::TestCase
  test "sends the license key via Loops when a delivery template is configured" do
    license = licenses(:cozy_active)
    license.product.update!(loops_transactional_id: "tx_deliver", sender_email: "team@cozy.app")

    captured = nil
    Loops.stub(:send_transactional, ->(**kwargs) { captured = kwargs }) do
      LicenseDeliveryJob.perform_now(license)
    end

    assert_equal "tx_deliver", captured[:transactional_id]
    assert_equal license.customer.email, captured[:email]
    assert_equal license.license_key, captured[:data][:license_key]
  end

  test "does nothing when the product has no delivery template" do
    license = licenses(:cozy_active)
    license.product.update!(loops_transactional_id: nil)

    called = false
    Loops.stub(:send_transactional, ->(**) { called = true }) do
      LicenseDeliveryJob.perform_now(license)
    end
    assert_not called
  end

  test "does nothing for an unclaimed license with no customer" do
    license = licenses(:cozy_unclaimed) # no customer
    license.product.update!(loops_transactional_id: "tx_deliver")

    called = false
    Loops.stub(:send_transactional, ->(**) { called = true }) do
      LicenseDeliveryJob.perform_now(license)
    end
    assert_not called
  end
end
