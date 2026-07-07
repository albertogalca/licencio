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
end
