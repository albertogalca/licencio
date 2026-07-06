require "test_helper"

class PortalAccessJobTest < ActiveJob::TestCase
  test "emails this product's keys and a product-scoped magic link" do
    license  = licenses(:cozy_active)
    customer = license.customer
    product  = license.product
    product.update!(loops_transactional_id: "tx_access", sender_email: "team@cozy.app")
    customer.update!(auth_token: "tok-abc", auth_token_expires_at: 30.minutes.from_now)

    captured = nil
    Loops.stub(:send_transactional, ->(**kwargs) { captured = kwargs }) do
      PortalAccessJob.perform_now(customer, product)
    end

    assert_equal "tx_access", captured[:transactional_id]
    assert_equal customer.email, captured[:email]
    assert_includes captured[:data][:license_keys], license.license_key
    assert_includes captured[:data][:magic_link_url], "tok-abc"
    assert_includes captured[:data][:magic_link_url], "product=#{product.slug}"
  end

  test "does nothing when the product has no template" do
    product = products(:cozy)
    product.update!(loops_transactional_id: nil)

    called = false
    Loops.stub(:send_transactional, ->(**) { called = true }) do
      PortalAccessJob.perform_now(customers(:alberto), product)
    end
    assert_not called
  end
end
