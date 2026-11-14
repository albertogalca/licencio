require "test_helper"

class Admin::DashboardControllerTest < ActionDispatch::IntegrationTest
  test "the overview has no trial tables: the cohorts API serves them" do
    products(:picmal).update!(trial_days: 7)
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
