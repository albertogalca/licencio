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

  test "upsert! reuses the existing customer on a concurrent-insert race" do
    existing = customers(:alberto)
    # Simulate the unique-index collision a second concurrent first-time webhook would hit.
    Customer.stub(:find_or_initialize_by, ->(*) { raise ActiveRecord::RecordNotUnique }) do
      assert_equal existing, Customer.upsert!(email: existing.email)
    end
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
    license = licenses(:cozy_active)
    assert_difference "PortalToken.count", 1 do
      assert_enqueued_with(job: LicenseEmailJob) do
        license.customer.send_refund_email_later(license:)
      end
    end
  end

  test "send_expiry_reminder_later enqueues the reminder for the license's product" do
    license = licenses(:picmal_expired) # time_limited — has an expires_at
    assert_enqueued_with(job: LicenseEmailJob) do
      license.customer.send_expiry_reminder_later(license:)
    end
  end

  # The reminder's whole point is the renew link, and it has to outlive the 30-minute magic
  # link sitting next to it in the same email.
  test "send_expiry_reminder_later carries a public renew_url keyed on the license" do
    license = licenses(:picmal_expired)
    license.customer.send_expiry_reminder_later(license:)

    job  = enqueued_jobs.find { |j| j["job_class"] == "LicenseEmailJob" }
    data = job["arguments"].last["data"].symbolize_keys
    assert_includes data[:renew_url], "/portal/renewals/new"
    assert_includes data[:renew_url], CGI.escape(license.license_key)
  end

  # Both one-shots used to key on the license id, so year two of an annual license sent
  # neither the renewal receipt nor the next reminder.
  test "a renewal's receipt and the next reminder are fresh one-shots, not spent ones" do
    license  = licenses(:picmal_expired)
    customer = license.customer

    Notification.once(customer:, kind: "purchase", reference_id: license.stripe_payment_id || license.id) { }
    Notification.once(customer:, kind: "expiry", reference_id: license.expiry_reference) { }

    license.renew!(stripe_payment_id: "pi_renewal_1")
    license.reload

    assert_not Notification.exists?(customer:, kind: "purchase", reference_id: license.stripe_payment_id),
      "the renewal payment is a receipt nobody has sent yet"
    assert_not Notification.exists?(customer:, kind: "expiry", reference_id: license.expiry_reference),
      "the new expiry window is a reminder nobody has sent yet"
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
