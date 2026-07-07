require "test_helper"

class Api::RecoveriesControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @product = products(:cozy)
    @headers = { "X-Api-Key" => @product.api_key }
  end

  def recover(email:, headers: @headers)
    post "/api/licenses/recover", params: { email: }, headers: headers, as: :json
  end

  test "a known email gets a magic link and returns 200" do
    assert_enqueued_with(job: PortalAccessJob) do
      recover(email: customers(:alberto).email)
    end
    assert_response :ok
    assert PortalToken.exists?(customer: customers(:alberto), product: @product)
  end

  test "an unknown email still returns 200 but enqueues nothing" do
    assert_no_enqueued_jobs do
      recover(email: "stranger@example.com")
    end
    assert_response :ok
  end

  test "a missing or wrong api key is unauthorized" do
    assert_no_enqueued_jobs do
      recover(email: customers(:alberto).email, headers: {})
      assert_response :unauthorized
      recover(email: customers(:alberto).email, headers: { "X-Api-Key" => "wrong" })
      assert_response :unauthorized
    end
  end
end
