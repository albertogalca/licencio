require "test_helper"

class V1::GiftsTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @product = products(:cozy)
    @product.update!(gift_card_url: "https://cozy.example/gift/card/", purchase_transactional_id: "tmpl_purchase")
    @gift = @product.gifts.create!(stripe_session_id: "cs_gift", stripe_payment_intent: "pi_gift",
      buyer_email: "giver@example.com", tier: "standard", update_policy: "time_limited",
      amount_cents: 4900, currency: "usd", to_name: "Ana", from_name: "Luis", note: "For the mornings.")
  end

  test "the card shows what is printed on it and never the buyer" do
    get "/v1/gifts/#{@gift.display_code}", params: { product_slug: "cozy" }
    assert_response :ok
    body = response.parsed_body
    assert_equal({ "code" => @gift.display_code, "tier" => "standard", "to" => "Ana", "from" => "Luis",
                   "note" => "For the mornings.", "state" => "ready" }, body)
    assert_equal "*", response.headers["Access-Control-Allow-Origin"]
  end

  test "a code typed loosely still finds the gift" do
    loose = @gift.display_code.downcase.tr("0", "o").tr("1", "l").tr("-", " ")
    get "/v1/gifts/#{ERB::Util.url_encode(loose)}", params: { product_slug: "cozy" }
    assert_response :ok
  end

  test "an unknown code, or another product's, is not found" do
    get "/v1/gifts/AAAA-BBBB-CCCC", params: { product_slug: "cozy" }
    assert_response :not_found
    assert_equal "gift_not_found", response.parsed_body["code"]

    get "/v1/gifts/#{@gift.display_code}", params: { product_slug: "picmal" }
    assert_response :not_found
  end

  test "the buyer finds the card again from the checkout session" do
    get "/v1/gifts/checkout/cs_gift", params: { product_slug: "cozy" }
    assert_response :ok
    assert_equal @gift.display_code, response.parsed_body["code"]

    get "/v1/gifts/checkout/cs_not_yet", params: { product_slug: "cozy" }
    assert_response :not_found
  end

  test "redeeming gives the recipient the license, the unlock and the receipt" do
    assert_enqueued_with(job: LicenseEmailJob) do
      post "/v1/gifts/#{@gift.display_code}/redeem", params: { product_slug: "cozy", email: " ana@example.com " }, as: :json
    end
    assert_response :ok
    assert_equal "ana@example.com", response.parsed_body["email"]

    license = @gift.reload.license
    assert_equal "ana@example.com", license.customer.email
    assert license.active?
    assert_equal "redeemed", @gift.state

    purchase = Purchase.for_email(@product, "ana@example.com").live.sole
    assert_equal "standard", purchase.tier
    assert_equal "pi_gift", purchase.provider_order_id
    assert_nil Customer.find_by(email: "giver@example.com")
  end

  test "redeeming a regionally priced gift reads the card's country for its payment" do
    @product.update!(region_token_secret: "shared-with-the-site")
    assert_enqueued_with(job: CardCountryJob, args: [ @product, "pi_gift" ]) do
      post "/v1/gifts/#{@gift.display_code}/redeem", params: { product_slug: "cozy", email: "ana@example.com" }, as: :json
    end
    assert_response :ok
  end

  test "a gift opens once" do
    post "/v1/gifts/#{@gift.display_code}/redeem", params: { product_slug: "cozy", email: "ana@example.com" }, as: :json
    assert_no_difference "License.count" do
      post "/v1/gifts/#{@gift.display_code}/redeem", params: { product_slug: "cozy", email: "eve@example.com" }, as: :json
    end
    assert_response :conflict
    assert_equal "gift_redeemed", response.parsed_body["code"]
  end

  test "a refunded gift cannot be opened" do
    Gift.refund!(product: @product, payment_intent: "pi_gift")
    post "/v1/gifts/#{@gift.display_code}/redeem", params: { product_slug: "cozy", email: "ana@example.com" }, as: :json
    assert_response :gone
    assert_equal "gift_refunded", response.parsed_body["code"]
    assert_nil Customer.find_by(email: "ana@example.com")
  end

  test "a bad address is refused before anything is issued" do
    assert_no_difference "License.count" do
      post "/v1/gifts/#{@gift.display_code}/redeem", params: { product_slug: "cozy", email: "ana" }, as: :json
    end
    assert_response :unprocessable_entity
  end
end
