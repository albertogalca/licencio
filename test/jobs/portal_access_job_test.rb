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

  test "each magic-link request sends, even though the token row is reused" do
    customer = customers(:alberto)
    product  = products(:cozy)
    product.update!(loops_transactional_id: "tx_access")

    sends = 0
    Loops.stub(:send_transactional, ->(**) { sends += 1 }) do
      2.times { PortalAccessJob.perform_now(PortalToken.issue!(customer:, product:)) }
    end
    assert_equal 2, sends, "a re-issued token (new string, same row id) must not be deduped away"
  end

  test "a single request's retries are still deduped (same token)" do
    customer = customers(:alberto)
    product  = products(:cozy)
    product.update!(loops_transactional_id: "tx_access")
    token = PortalToken.issue!(customer:, product:)

    sends = 0
    Loops.stub(:send_transactional, ->(**) { sends += 1 }) do
      2.times { PortalAccessJob.perform_now(token) }
    end
    assert_equal 1, sends, "the same token (a retry) is deduped"
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
