require "test_helper"

class Admin::DashboardControllerTest < ActionDispatch::IntegrationTest
  test "the overview shows trial conversion for a product that offers a trial" do
    product = products(:picmal)
    product.update!(trial_days: 7)
    travel_to(10.days.ago) { product.trial_for(hardware_id: "HW-1") }
    product.licenses.create!(status: "active", max_activations: 1).activate!(hardware_id: "HW-1")

    sign_in
    get admin_root_path
    assert_response :success
    assert_select "h2", text: "Picmal trials"
    assert_select "table.data-table td", text: "100.0%"
  end

  test "no trial section when no product offers a trial" do
    sign_in
    get admin_root_path
    assert_response :success
    assert_select "h2", text: /trials/, count: 0
  end

  private
    def sign_in
      post admin_session_path, params: { email: "admin@licencio.example", password: "secret123" }
    end
end
