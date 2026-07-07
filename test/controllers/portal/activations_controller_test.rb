require "test_helper"

class Portal::ActivationsControllerTest < ActionDispatch::IntegrationTest
  test "deactivating a device frees the seat" do
    sign_in customers(:alberto)
    activation = activations(:cozy_macbook)
    license = activation.license
    assert_includes license.activations.active, activation

    assert_difference -> { license.activations.active.count }, -1 do
      delete portal_activation_path(activation)
    end
    assert_redirected_to portal_root_path
    assert activation.reload.deactivated_at.present?
    assert_not_includes license.activations.active, activation
  end

  test "cannot deactivate a device outside the session's product or another customer" do
    # nameless owns the picmal license; give picmal_expired an active device.
    foreign = licenses(:picmal_expired).activations.create!(
      hardware_id: "HW-FOREIGN", activated_at: Time.current)

    sign_in customers(:alberto) # signed into cozy
    delete portal_activation_path(foreign)
    assert_redirected_to portal_root_path # scoped-out device: no-op, not a 500
    assert_nil foreign.reload.deactivated_at
  end

  private
    def sign_in(customer, product: products(:cozy))
      token = PortalToken.issue!(customer:, product:)
      get portal_session_path(token: token.token)
    end
end
