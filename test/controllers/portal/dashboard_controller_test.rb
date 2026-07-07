require "test_helper"

class Portal::DashboardControllerTest < ActionDispatch::IntegrationTest
  Stub = Struct.new(:id, :nickname, :unit_amount, :metadata, :data, keyword_init: true)

  test "requires a signed-in customer" do
    get portal_root_path
    assert_redirected_to new_portal_recovery_path
  end

  test "shows only the signed-in customer's own licenses" do
    sign_in customers(:alberto)

    get portal_root_path
    assert_response :ok
    assert_includes response.body, licenses(:cozy_active).license_key    # alberto's
    assert_not_includes response.body, licenses(:picmal_expired).license_key # nameless's
  end

  test "a lifetime product shows no renew form and never hits Stripe" do
    sign_in customers(:alberto) # cozy is lifetime

    called = false
    Stripe::Price.stub(:list, ->(*_) { called = true; Stub.new(data: []) }) do
      get portal_root_path
    end
    assert_response :ok
    assert_not_includes response.body, "Renew license"
    assert_not called, "lifetime dashboard must not fetch Stripe variants"
  end

  test "a time-limited product shows a renew form" do
    price = Stub.new(id: "price_1", nickname: "1 seat", unit_amount: 1900, metadata: {})
    Stripe::Price.stub(:list, ->(*_) { Stub.new(data: [ price ]) }) do
      sign_in customers(:nameless), product: products(:picmal)
      get portal_root_path
    end
    assert_response :ok
    assert_includes response.body, "Renew license"
  end

  private
    def sign_in(customer, product: products(:cozy))
      token = PortalToken.issue!(customer:, product:)
      get portal_session_path(token: token.token)
    end
end
