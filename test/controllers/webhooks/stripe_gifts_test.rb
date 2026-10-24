require "test_helper"

class Webhooks::StripeGiftsTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @secret = "whsec_test"
    @product = products(:cozy)
    @product.update!(stripe_product_id: "prod_cozy", stripe_secret_key: "sk_test_cozy", stripe_webhook_secret: @secret,
      checkout_success_url: "https://cozy.example/thanks", checkout_cancel_url: "https://cozy.example/",
      gift_card_url: "https://cozy.example/gift/card/", gift_transactional_id: "tmpl_gift",
      purchase_transactional_id: "tmpl_purchase")
  end

  test "a gift checkout mints a code and mails the card, and no license or purchase" do
    assert_no_difference [ "License.count", "Purchase.count", "Customer.count" ] do
      assert_enqueued_with(job: GiftEmailJob) do
        post_event gift_event
      end
    end
    assert_response :ok

    gift = Gift.last
    assert_equal "giver@example.com", gift.buyer_email
    assert_equal [ "Ana", "Luis", "For the mornings." ], [ gift.to_name, gift.from_name, gift.note ]
    assert_equal "forever", gift.tier
    assert_equal "cs_pi_gift", gift.stripe_session_id
    assert_equal "ready", gift.state
    assert_match(/\A[0-9A-HJKMNP-TV-Z]{12}\z/, gift.code)
  end

  test "a redelivered gift checkout makes one gift and one card" do
    post_event gift_event
    assert_no_difference "Gift.count" do
      assert_no_enqueued_jobs(only: GiftEmailJob) { post_event gift_event }
    end
  end

  test "empty card fields are stored as nothing" do
    post_event gift_event(fields: [ { key: "to", type: "text", text: { value: "  " } }, { key: "note", type: "text" } ])
    gift = Gift.last
    assert_nil gift.to_name
    assert_nil gift.note
  end

  test "a refund before redemption voids the gift" do
    post_event gift_event
    post_event refunded_event
    assert_equal "refunded", Gift.last.state
  end

  test "a refund after redemption revokes the recipient's license and purchase" do
    post_event gift_event
    gift = Gift.last
    gift.redeem!(email: "ana@example.com")

    post_event refunded_event
    assert gift.license.reload.refunded?
    assert_not_nil Purchase.find_by(provider_order_id: "pi_gift").refunded_at
  end

  private
    def gift_event(fields: default_fields)
      { type: "checkout.session.completed",
        data: { object: {
          id: "cs_pi_gift", customer: "cus_giver",
          customer_details: { email: "giver@example.com" },
          metadata: { licencio_product_id: @product.id, price_id: "price_forever", gift: "1" },
          custom_fields: fields,
          payment_status: "paid", payment_intent: "pi_gift",
          amount_total: 8900, currency: "usd" } } }.to_json
    end

    def default_fields
      [ { key: "to", type: "text", text: { value: "Ana" } },
        { key: "from", type: "text", text: { value: "Luis" } },
        { key: "note", type: "text", text: { value: "For the mornings." } } ]
    end

    def refunded_event
      { type: "charge.refunded",
        data: { object: { payment_intent: "pi_gift", amount: 8900, amount_captured: 8900, amount_refunded: 8900 } } }.to_json
    end

    def post_event(payload)
      price = Struct.new(:id, :product, :metadata)
        .new("price_forever", "prod_cozy", { "tier" => "forever", "update_policy" => "lifetime", "seats" => "unlimited" })
      line_items = Struct.new(:data).new([ Struct.new(:price).new(price) ])
      Stripe::Checkout::Session.stub(:list_line_items, line_items) do
        post "/webhooks/stripe/#{@product.id}", params: payload, headers: signed(payload)
      end
    end

    def signed(payload)
      ts  = Time.now.to_i
      sig = OpenSSL::HMAC.hexdigest("SHA256", @secret, "#{ts}.#{payload}")
      { "Stripe-Signature" => "t=#{ts},v1=#{sig}", "CONTENT_TYPE" => "application/json" }
    end
end
