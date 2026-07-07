require "test_helper"

class PortalAccessJobTest < ActiveJob::TestCase
  test "emails this product's keys and the token's magic link" do
    license  = licenses(:cozy_active)
    customer = license.customer
    product  = license.product
    product.update!(loops_transactional_id: "tx_access", sender_email: "team@cozy.app")
    token = PortalToken.issue!(customer:, product:)

    captured = nil
    Loops.stub(:send_transactional, ->(**kwargs) { captured = kwargs }) do
      PortalAccessJob.perform_now(token)
    end

    assert_equal "tx_access", captured[:transactional_id]
    assert_equal customer.email, captured[:email]
    assert_includes captured[:data][:license_keys], license.license_key
    assert_includes captured[:data][:magic_link_url], token.token
  end

  test "does nothing when the product has no template" do
    product = products(:cozy)
    product.update!(loops_transactional_id: nil)
    token = PortalToken.issue!(customer: customers(:alberto), product:)

    called = false
    Loops.stub(:send_transactional, ->(**) { called = true }) do
      PortalAccessJob.perform_now(token)
    end
    assert_not called
  end
end
