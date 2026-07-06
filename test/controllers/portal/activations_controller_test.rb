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

  test "cannot deactivate another customer's device" do
    # nameless owns the picmal license; give picmal_expired an active device.
    foreign = licenses(:picmal_expired).activations.create!(
      hardware_id: "HW-FOREIGN", activated_at: Time.current)

    sign_in customers(:alberto)
    delete portal_activation_path(foreign)
    assert_response :not_found
    assert_nil foreign.reload.deactivated_at
  end

  private
    def sign_in(customer)
      customer.update!(auth_token: "tok-#{customer.id}", auth_token_expires_at: 10.minutes.from_now)
      get portal_session_path(token: customer.auth_token, product: "cozy")
    end
end
