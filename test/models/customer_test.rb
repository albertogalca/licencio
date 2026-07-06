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

  test "authenticate_token returns the customer for a valid, unexpired token" do
    customer = customers(:alberto)
    customer.update!(auth_token: "good-token", auth_token_expires_at: 10.minutes.from_now)
    assert_equal customer, Customer.authenticate_token("good-token")
  end

  test "authenticate_token rejects an expired token" do
    customers(:alberto).update!(auth_token: "old-token", auth_token_expires_at: 1.minute.ago)
    assert_nil Customer.authenticate_token("old-token")
  end

  test "authenticate_token rejects blank and unknown tokens" do
    assert_nil Customer.authenticate_token(nil)
    assert_nil Customer.authenticate_token("")
    assert_nil Customer.authenticate_token("nope")
  end

  test "send_portal_access_later sets a fresh token and enqueues the job for a license holder" do
    customer = customers(:alberto) # owns a cozy license
    assert_enqueued_with(job: PortalAccessJob, args: [ customer, products(:cozy) ]) do
      customer.send_portal_access_later(product: products(:cozy))
    end
    customer.reload
    assert customer.auth_token.present?
    assert customer.auth_token_expires_at > Time.current
  end

  test "send_portal_access_later is a no-op when the customer has no license for that product" do
    customer = customers(:nameless) # owns a picmal license, not cozy
    assert_no_enqueued_jobs do
      customer.send_portal_access_later(product: products(:cozy))
    end
    assert_nil customer.reload.auth_token # token not rotated
  end

  test "clear_auth_token! wipes the token" do
    customer = customers(:alberto)
    customer.update!(auth_token: "t", auth_token_expires_at: 1.hour.from_now)
    customer.clear_auth_token!
    assert_nil customer.reload.auth_token
    assert_nil customer.auth_token_expires_at
  end
end
