require "test_helper"

class Admin::ActivationsControllerTest < ActionDispatch::IntegrationTest
  test "requires admin sign-in" do
    delete admin_activation_path(activations(:cozy_macbook))
    assert_redirected_to new_admin_session_path
  end

  test "deactivating an active device frees the seat" do
    sign_in
    activation = activations(:cozy_macbook)
    assert_nil activation.deactivated_at

    assert_difference -> { activation.license.activations.active.count }, -1 do
      delete admin_activation_path(activation)
    end
    assert_redirected_to edit_admin_license_path(activation.license)
    assert activation.reload.deactivated_at.present?
  end

  test "deactivating an already-deactivated device is not found" do
    sign_in
    delete admin_activation_path(activations(:cozy_deactivated))
    assert_response :not_found
  end

  private
    def sign_in
      post admin_session_path, params: { email: "admin@licencio.example", password: "secret123" }
    end
end
