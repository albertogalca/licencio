require "test_helper"

class Api::Admin::TrialsControllerTest < ActionDispatch::IntegrationTest
  setup do
    ENV["ADMIN_API_KEY"] = "admin-secret"
    @headers = { "Authorization" => "Bearer admin-secret" }
    @product = products(:picmal)
    @product.update!(trial_days: 7)
  end

  def trials(slug: @product.slug, from: "2026-10-05", to: "2026-10-11", headers: @headers)
    get "/api/admin/products/#{slug}/trials", params: { from:, to: }.compact, headers:
  end

  test "counts what happened to every trial during the week, internal ones left out" do
    trial = ->(hardware_id, at) { travel_to(at) { @product.trial_for(hardware_id:) } }
    paid = lambda do |hardware_id, at, status: "active"|
      travel_to(at) { @product.licenses.create!(status:, max_activations: 1).activate!(hardware_id:) }
    end

    trial.("HW-LATE", Time.utc(2026, 9, 20, 12))          # expired 27 Sep, bought in the week
    paid.("HW-LATE", Time.utc(2026, 10, 6, 12))
    trial.("HW-QUICK", Time.utc(2026, 10, 6, 12))         # started and bought in the week
    paid.("HW-QUICK", Time.utc(2026, 10, 8, 12))
    trial.("HW-MISS", Time.utc(2026, 10, 2, 12))          # expires in the week, never bought
    trial.("HW-EARLY", Time.utc(2026, 10, 1, 12))         # expires in the week, bought before it
    paid.("HW-EARLY", Time.utc(2026, 10, 4, 12))
    trial.("HW-REFUND", Time.utc(2026, 10, 3, 12))        # a refunded purchase is no sale
    paid.("HW-REFUND", Time.utc(2026, 10, 5, 12), status: "refunded")
    trial.("HW-NEW", Time.utc(2026, 10, 9, 12))           # started, still running
    trial.("HW-SUNDAY", Time.utc(2026, 10, 11, 23, 30))   # last minutes of `to`, bought after it
    paid.("HW-SUNDAY", Time.utc(2026, 10, 13, 12))
    trial.("HW-MONDAY", Time.utc(2026, 10, 12, 0, 0))     # the day after `to`
    trial.("HW-OWNER", Time.utc(2026, 10, 7, 12)).update!(internal: true)

    trials
    assert_response :ok
    assert_equal({ "product" => "picmal", "trial_days" => 7, "from" => "2026-10-05", "to" => "2026-10-11",
      "started" => 3, "bought" => 2, "expired" => 2, "running" => 2, "median_days_to_buy" => 9.0 },
      response.parsed_body)
  end

  test "a product without a trial reports zeros" do
    trials(slug: products(:cozy).slug)
    assert_response :ok
    assert_equal({ "product" => "cozy", "trial_days" => nil, "from" => "2026-10-05", "to" => "2026-10-11",
      "started" => 0, "bought" => 0, "expired" => 0, "running" => 0, "median_days_to_buy" => nil },
      response.parsed_body)
  end

  test "needs the admin key" do
    trials(headers: {})
    assert_response :unauthorized
    trials(headers: { "Authorization" => "Bearer wrong" })
    assert_response :unauthorized
  end

  test "refuses missing, malformed or reversed dates" do
    [ { from: nil }, { to: "2026-13-01" }, { from: "last week" }, { from: "2026-10-12", to: "2026-10-11" } ]
      .each do |dates|
        trials(**dates)
        assert_response :bad_request, dates.inspect
        assert_equal "invalid_dates", response.parsed_body["code"]
      end
  end

  test "an unknown product is a 404" do
    trials(slug: "nope")
    assert_response :not_found
  end
end
