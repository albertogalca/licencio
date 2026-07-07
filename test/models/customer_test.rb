require "test_helper"

class CustomerTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  test "fixtures are valid" do
    assert customers(:alberto).valid?
    assert customers(:nameless).valid?
  end

  test "requires email" do
    customer = Customer.new
    assert_not customer.valid?
    assert_includes customer.errors.attribute_names, :email
  end

  test "email is unique" do
    dup = Customer.new(email: customers(:alberto).email)
    assert_not dup.valid?
    assert_includes dup.errors.attribute_names, :email
  end

  test "stripe_customer_id is unique but optional" do
    assert Customer.new(email: "new@example.com").valid?

    dup = Customer.new(email: "new@example.com", stripe_customer_id: customers(:alberto).stripe_customer_id)
    assert_not dup.valid?
    assert_includes dup.errors.attribute_names, :stripe_customer_id
  end

  test "has many licenses" do
    assert_equal 1, customers(:alberto).licenses.count
  end

  test "send_portal_access_later issues a product-scoped token and enqueues the job for a license holder" do
    customer = customers(:alberto) # owns a cozy license
    assert_difference "PortalToken.count", 1 do
      assert_enqueued_with(job: PortalAccessJob) do
        customer.send_portal_access_later(product: products(:cozy))
      end
    end
    token = customer.portal_tokens.find_by(product: products(:cozy))
    assert token.token.present?
    assert token.expires_at > Time.current
  end

  test "send_portal_access_later is a no-op when the customer has no license for that product" do
    customer = customers(:nameless) # owns a picmal license, not cozy
    assert_no_enqueued_jobs do
      assert_no_difference "PortalToken.count" do
        customer.send_portal_access_later(product: products(:cozy))
      end
    end
  end

  test "tokens for two products coexist — requesting one does not clobber the other" do
    customer = customers(:alberto)
    PortalToken.issue!(customer:, product: products(:cozy))
    PortalToken.issue!(customer:, product: products(:picmal))
    assert_equal 2, customer.portal_tokens.count
  end

  test "send_purchase_email_later issues a token and enqueues a receipt for only that license's key" do
    license  = licenses(:cozy_active)
    customer = license.customer
    assert_difference "PortalToken.count", 1 do
      assert_enqueued_with(job: LicenseEmailJob) do
        customer.send_purchase_email_later(license:, amount: 2999, currency: "eur")
      end
    end
    job = enqueued_jobs.find { |j| j["job_class"] == "LicenseEmailJob" }
    data = job["arguments"].last["data"]
    assert_equal license.license_key, data[:license_keys] || data["license_keys"]
  end

  test "send_refund_email_later issues a token and enqueues the refund email for a license holder" do
    customer = customers(:alberto)
    assert_difference "PortalToken.count", 1 do
      assert_enqueued_with(job: LicenseEmailJob) do
        customer.send_refund_email_later(product: products(:cozy))
      end
    end
  end

  test "send_expiry_reminder_later enqueues the reminder for the license's product" do
    license = licenses(:picmal_expired) # time_limited — has an expires_at
    assert_enqueued_with(job: LicenseEmailJob) do
      license.customer.send_expiry_reminder_later(license:)
    end
  end

  test "unsubscribe_from_loops_later enqueues an unsubscribe when no active license remains" do
    customer = customers(:nameless) # picmal_expired is not active
    assert_enqueued_with(job: LoopsContactJob,
      args: [ customer, products(:picmal), { subscribed: false } ]) do
      customer.unsubscribe_from_loops_later(product: products(:picmal))
    end
  end

  test "unsubscribe_from_loops_later skips while an active license for the product remains" do
    customer = customers(:alberto) # cozy_active is still active
    assert_no_enqueued_jobs only: LoopsContactJob do
      customer.unsubscribe_from_loops_later(product: products(:cozy))
    end
  end
end
