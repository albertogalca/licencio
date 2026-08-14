require "test_helper"

class V1::SupportControllerTest < ActionDispatch::IntegrationTest
  TOKEN = "support-secret-token"

  setup do
    @product = products(:cozy)
    @product.update!(unlock_transactional_id: "tmpl_cozy_unlock")
    ENV["SUPPORT_ADMIN_TOKEN"] = TOKEN
  end

  teardown { ENV.delete("SUPPORT_ADMIN_TOKEN") }

  def lookup(email: "anaperez@gmail.com", token: TOKEN, **params)
    headers = token ? { "X-Admin-Token" => token } : {}
    post "/v1/support/lookup", params: { product_slug: @product.slug, email:, **params },
      headers:, as: :json
  end

  test "a missing or wrong token is refused" do
    lookup(token: nil)
    assert_response :unauthorized
    assert_equal "unauthorized", response.parsed_body["code"]

    lookup(token: "nope")
    assert_response :unauthorized
  end

  test "an unset SUPPORT_ADMIN_TOKEN refuses everyone, including an empty header" do
    ENV.delete("SUPPORT_ADMIN_TOKEN")
    lookup(token: "")
    assert_response :unauthorized
  end

  test "lookup returns every purchase for the address, refunds included" do
    lookup
    assert_response :ok

    purchase = response.parsed_body["purchases"].sole
    assert_equal purchases(:cozy_forever).id, purchase["id"]
    assert_equal purchases(:cozy_forever).email, purchase["email"], "the address as the buyer typed it"
    assert_equal "forever", purchase["tier"]
    assert_nil purchase["updates_until"]
    assert_nil purchase["refunded_at"]
    assert_equal %w[mac windows iphone], purchase["platforms"]
    assert_equal "stripe", purchase["provider"]
    assert_equal "pi_cozy_forever", purchase["provider_order_id"]
    assert purchase["purchased_at"]
    assert_equal false, response.parsed_body["code_sent"]
  end

  test "a refunded purchase is visible, which is the point" do
    lookup(email: purchases(:cozy_refunded).email)
    assert response.parsed_body["purchases"].sole["refunded_at"]
  end

  test "an address that bought nothing lists nothing" do
    lookup(email: "stranger@example.com")
    assert_response :ok
    assert_empty response.parsed_body["purchases"]
  end

  test "resend_code mails a code past the per-address budget" do
    assert_difference "LoginCode.count", 1 do
      Loops.stub :send_transactional, ->(**) { :sent } do
        lookup(resend_code: true)
      end
    end
    assert_equal true, response.parsed_body["code_sent"]
  end

  test "resend_code reports honestly when there was nothing to send to" do
    assert_no_difference "LoginCode.count" do
      lookup(email: "stranger@example.com", resend_code: true)
    end
    assert_equal false, response.parsed_body["code_sent"]
  end

  test "an unknown product is not found" do
    post "/v1/support/lookup", params: { product_slug: "nope", email: "a@b.com" },
      headers: { "X-Admin-Token" => TOKEN }, as: :json
    assert_response :not_found
  end
end
