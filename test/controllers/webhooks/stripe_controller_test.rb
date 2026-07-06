require "test_helper"

class Webhooks::StripeControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @secret = "whsec_test"
    @product = products(:picmal) # time_limited, update_duration_days: 365
    @product.update!(stripe_webhook_secret: @secret)
  end

  test "invalid signature is rejected and fulfills nothing" do
    payload = completed_event
    assert_no_difference "License.count" do
      post "/webhooks/stripe/#{@product.id}", params: payload,
        headers: { "Stripe-Signature" => "t=123,v1=deadbeef" }
    end
    assert_response :bad_request
  end

  test "metadata routes the license to the correct product" do
    assert_difference "License.count", 1 do
      post_event completed_event
    end
    assert_response :ok
    assert_equal @product, License.order(:created_at).last.product
  end

  test "quantity greater than one sets max_activations to the quantity" do
    post_event completed_event(quantity: 5)
    assert_equal 5, License.order(:created_at).last.max_activations
  end

  test "a repeat purchase without a renew key issues a new license" do
    post_event completed_event(payment_intent: "pi_1")
    assert_difference "License.count", 1 do
      post_event completed_event(payment_intent: "pi_2") # same buyer, no renew key
    end
    assert_response :ok
  end

  test "a renewal key extends the targeted license instead of creating a new one" do
    post_event completed_event(payment_intent: "pi_1")
    license = License.order(:created_at).last
    assert_in_delta 365.days.from_now.to_i, license.expires_at.to_i, 1.hour

    assert_no_difference "License.count" do
      post_event completed_event(payment_intent: "pi_2", renew_license_key: license.license_key)
    end
    assert_response :ok
    assert_in_delta 730.days.from_now.to_i, license.reload.expires_at.to_i, 1.hour
  end

  test "a renewal key belonging to a different buyer issues a new license instead" do
    post_event completed_event(email: "owner@example.com", stripe_customer: "cus_owner", payment_intent: "pi_1")
    victim = License.order(:created_at).last

    assert_difference "License.count", 1 do
      post_event completed_event(email: "attacker@example.com", stripe_customer: "cus_attacker",
        payment_intent: "pi_2", renew_license_key: victim.license_key)
    end
    assert_equal victim.expires_at.to_i, victim.reload.expires_at.to_i, "victim's license untouched"
  end

  test "a completed purchase enqueues the portal access email" do
    assert_enqueued_with(job: PortalAccessJob) do
      post_event completed_event
    end
  end

  test "charge.refunded marks the matching license refunded" do
    post_event completed_event(payment_intent: "pi_ref")
    license = License.order(:created_at).last
    assert license.active?

    post_event refunded_event(payment_intent: "pi_ref")
    assert_response :ok
    assert license.reload.refunded?
  end

  test "a duplicate completed event fulfills only once" do
    post_event completed_event(payment_intent: "pi_dup")
    assert_no_difference "License.count" do
      post_event completed_event(payment_intent: "pi_dup")
    end
    assert_response :ok
  end

  test "an unknown product id in the URL is not found" do
    payload = completed_event
    post "/webhooks/stripe/#{SecureRandom.uuid}", params: payload, headers: signed(payload)
    assert_response :not_found
  end

  private
    def refunded_event(payment_intent:)
      { type: "charge.refunded", data: { object: { payment_intent: } } }.to_json
    end

    def completed_event(email: "buyer@example.com", product_id: @product.id,
                        quantity: 1, payment_intent: "pi_test", renew_license_key: nil,
                        stripe_customer: "cus_buyer")
      metadata = { licencio_product_id: product_id, quantity: quantity.to_s }
      metadata[:renew_license_key] = renew_license_key if renew_license_key
      {
        type: "checkout.session.completed",
        data: { object: {
          customer: stripe_customer,
          customer_details: { email: },
          metadata:,
          payment_intent:
        } }
      }.to_json
    end

    def post_event(payload)
      post "/webhooks/stripe/#{@product.id}", params: payload, headers: signed(payload)
    end

    # CONTENT_TYPE json keeps the body byte-for-byte; form-encoding would break the signature.
    def signed(payload)
      ts  = Time.now.to_i
      sig = OpenSSL::HMAC.hexdigest("SHA256", @secret, "#{ts}.#{payload}")
      { "Stripe-Signature" => "t=#{ts},v1=#{sig}", "CONTENT_TYPE" => "application/json" }
    end
end
