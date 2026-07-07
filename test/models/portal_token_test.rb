require "test_helper"

class PortalTokenTest < ActiveSupport::TestCase
  test "issue! replaces a customer's prior token for the SAME product" do
    customer = customers(:alberto)
    first  = PortalToken.issue!(customer:, product: products(:cozy))
    second = PortalToken.issue!(customer:, product: products(:cozy))

    assert_equal 1, customer.portal_tokens.where(product: products(:cozy)).count
    assert_not_equal first.token, second.token
  end

  test "authenticate returns the token when live, nil when expired/blank/unknown" do
    token = PortalToken.issue!(customer: customers(:alberto), product: products(:cozy))
    assert_equal token, PortalToken.authenticate(token.token)

    token.update!(expires_at: 1.minute.ago)
    assert_nil PortalToken.authenticate(token.token)
    assert_nil PortalToken.authenticate(nil)
    assert_nil PortalToken.authenticate("nope")
  end

  test "the token carries its own product binding" do
    token = PortalToken.issue!(customer: customers(:alberto), product: products(:picmal))
    assert_equal products(:picmal), PortalToken.authenticate(token.token).product
  end
end
