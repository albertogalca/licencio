require "test_helper"

class Webhooks::StripeAnalyticsTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  REFERENCE = "123.456.789"

  setup do
    @product = Product.find_by!(update_policy: "time_limited")
    @product.update!(stripe_webhook_secret: "whsec_test", ga4_measurement_id: "G-TEST", ga4_api_secret: "s3cret")
  end

  test "a sale that carries a visit is reported once, however often Stripe delivers it" do
    assert_enqueued_with(job: PurchaseAnalyticsJob, args: [ @product, { reference: REFERENCE,
      transaction_id: "cs_1", amount: 2999, currency: "usd", item: "price_1" } ]) { post_sale }
    assert_no_enqueued_jobs(only: PurchaseAnalyticsJob) { post_sale }
  end

  test "a gift is reported once too" do
    @product.update!(gift_transactional_id: "tmpl_gift", gift_card_url: "https://example.com/gift/")
    assert_enqueued_jobs(1, only: PurchaseAnalyticsJob) { 2.times { post_sale(gift: "1") } }
  end

  test "a sale with no visit, or somebody else's id, is not reported" do
    [ nil, "ph_abc" ].each_with_index do |reference, i|
      assert_no_enqueued_jobs(only: PurchaseAnalyticsJob) { post_sale(reference:, intent: "pi_#{i}") }
      assert_response :ok
    end
  end

  test "a product without analytics reports nothing, and still sells" do
    @product.update!(ga4_api_secret: nil)
    assert_difference "License.count", 1 do
      assert_no_enqueued_jobs(only: PurchaseAnalyticsJob) { post_sale }
    end
  end

  test "an unpaid session is not a sale" do
    assert_no_enqueued_jobs(only: PurchaseAnalyticsJob) { post_sale(payment_status: "unpaid") }
  end

  private
    def post_sale(reference: REFERENCE, intent: "pi_1", payment_status: "paid", **metadata)
      payload = { type: "checkout.session.completed", data: { object: {
        id: "cs_1", customer: "cus_1", customer_details: { email: "buyer@example.com" },
        client_reference_id: reference, payment_status:, payment_intent: intent, amount_total: 2999, currency: "usd",
        metadata: { licencio_product_id: @product.id, quantity: "1", price_id: "price_1", **metadata } } } }.to_json
      timestamp = Time.now.to_i
      signature = OpenSSL::HMAC.hexdigest("SHA256", "whsec_test", "#{timestamp}.#{payload}")
      price = Struct.new(:id, :product, :metadata).new("price_1", @product.stripe_product_id, { "seats" => "1" })
      Stripe::Checkout::Session.stub(:list_line_items, Struct.new(:data).new([ Struct.new(:price).new(price) ])) do
        post "/webhooks/stripe/#{@product.id}", params: payload,
          headers: { "Stripe-Signature" => "t=#{timestamp},v1=#{signature}", "CONTENT_TYPE" => "application/json" }
      end
    end
end
