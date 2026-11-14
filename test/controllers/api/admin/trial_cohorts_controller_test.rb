require "test_helper"

class Api::Admin::TrialCohortsControllerTest < ActionDispatch::IntegrationTest
  setup do
    ENV["ADMIN_API_KEY"] = "admin-secret"
    @headers = { "Authorization" => "Bearer admin-secret" }
    @product = products(:picmal)
    @product.update!(trial_days: 7)
  end

  def cohorts(slug: @product.slug, headers: @headers)
    get "/api/admin/products/#{slug}/trials/cohorts", headers:
  end

  test "groups trials by the week they started, newest first" do
    travel_to(Time.utc(2026, 10, 1, 12)) { @product.trial_for(hardware_id: "HW-BUY") }
    travel_to(Time.utc(2026, 10, 3, 12)) do
      @product.licenses.create!(status: "active", max_activations: 1).activate!(hardware_id: "HW-BUY")
    end
    travel_to(Time.utc(2026, 10, 2, 12)) { @product.trial_for(hardware_id: "HW-MISS") }
    travel_to(Time.utc(2026, 10, 13, 12)) { @product.trial_for(hardware_id: "HW-NEW") }

    travel_to(Time.utc(2026, 10, 14, 12)) { cohorts }
    assert_response :ok
    assert_equal({ "product" => "picmal", "trial_days" => 7, "weeks" => 8,
      "total" => { "week" => nil, "started" => 3, "running" => 1, "bought" => 1, "median_days_to_buy" => 2.0 },
      "cohorts" => [
        { "week" => "2026-10-12", "started" => 1, "running" => 1, "bought" => 0, "median_days_to_buy" => nil },
        { "week" => "2026-09-28", "started" => 2, "running" => 0, "bought" => 1, "median_days_to_buy" => 2.0 }
      ] }, response.parsed_body)
  end

  test "a product without a trial has no cohorts" do
    cohorts(slug: products(:cozy).slug)
    assert_response :ok
    assert_equal [], response.parsed_body["cohorts"]
  end

  test "needs the admin key" do
    cohorts(headers: {})
    assert_response :unauthorized
  end

  test "an unknown product is a 404" do
    cohorts(slug: "nope")
    assert_response :not_found
  end
end
