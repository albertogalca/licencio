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

  test "a completed purchase enqueues the receipt email and a subscribe contact sync" do
    assert_enqueued_with(job: LicenseEmailJob) do
      assert_enqueued_with(job: LoopsContactJob) do
        post_event completed_event
      end
    end
  end

  test "a completed purchase stores the name Stripe collected, and tolerates its absence" do
    post_event completed_event(email: "named@example.com", name: "Ada Lovelace", payment_intent: "pi_named")
    assert_equal "Ada Lovelace", Customer.find_by(email: "named@example.com").name

    post_event completed_event(email: "anon@example.com", payment_intent: "pi_anon")
    assert_nil Customer.find_by(email: "anon@example.com").name
  end

  test "a refund enqueues an unsubscribe contact sync and a refund email" do
    post_event completed_event(payment_intent: "pi_unsub")
    assert_enqueued_with(job: LicenseEmailJob) do
      assert_enqueued_with(job: LoopsContactJob) do
        post_event refunded_event(payment_intent: "pi_unsub")
      end
    end
  end

  test "a refund does not unsubscribe while the buyer keeps another active license" do
    # Same buyer, two purchases of this product; refunding one leaves the other active.
    post_event completed_event(payment_intent: "pi_a")
    post_event completed_event(payment_intent: "pi_b")
    assert_no_enqueued_jobs only: LoopsContactJob do
      post_event refunded_event(payment_intent: "pi_a")
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

  test "a partial refund leaves the license active" do
    post_event completed_event(payment_intent: "pi_part")
    license = License.order(:created_at).last

    post_event refunded_event(payment_intent: "pi_part", amount: 1000, amount_refunded: 400)
    assert_response :ok
    assert license.reload.active?, "partial refund must not revoke the license"
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

  test "a signed event whose metadata names a different product mints nothing" do
    # Signed with @product's (picmal) secret but pointing at cozy — must not fulfill.
    other = products(:cozy)
    assert_no_difference "License.count" do
      post_event completed_event(product_id: other.id)
    end
    assert_response :ok
  end

  test "a refund only revokes licenses on the endpoint's own product" do
    post_event completed_event(payment_intent: "pi_scoped")
    victim = License.order(:created_at).last
    # A cozy license sharing the payment id must be untouched by picmal's endpoint.
    foreign = products(:cozy).licenses.create!(status: "active", max_activations: 1, stripe_payment_id: "pi_scoped")

    post_event refunded_event(payment_intent: "pi_scoped")
    assert victim.reload.refunded?
    assert foreign.reload.active?, "another product's license must not be revoked"
  end

  test "refunding the original purchase revokes a license that was later renewed (H4b)" do
    post_event completed_event(payment_intent: "pi_orig")
    license = License.order(:created_at).last
    post_event completed_event(payment_intent: "pi_renew", renew_license_key: license.license_key)
    assert_equal "pi_renew", license.reload.stripe_payment_id, "renewal overwrote the latest intent"

    # The original charge is refunded (a chargeback on the first payment) — must still revoke.
    post_event refunded_event(payment_intent: "pi_orig")
    assert license.reload.refunded?, "found via payment history, not the license's latest intent"
  end

  test "a redelivered charge.refunded revokes once and re-enqueues no refund email (H4a)" do
    post_event completed_event(payment_intent: "pi_ridem")
    clear_enqueued_jobs

    assert_enqueued_jobs 1, only: LicenseEmailJob do
      post_event refunded_event(payment_intent: "pi_ridem") # first delivery
      post_event refunded_event(payment_intent: "pi_ridem") # Stripe redelivery
    end
    assert_response :ok
  end

  test "stores the Stripe customer id on the license, not the shared customer (M3)" do
    post_event completed_event(payment_intent: "pi_cust", stripe_customer: "cus_xyz")
    assert_equal "cus_xyz", License.order(:created_at).last.stripe_customer_id
  end

  # ── Unlock purchases ──────────────────────────────────────────────────────────
  # The same sale mints a license AND records a purchase; the license-key system is
  # untouched, and the unlock flow is opted into by a `tier` on the price.

  test "a tiered price records a purchase alongside the license" do
    assert_difference [ "License.count", "Purchase.count" ], 1 do
      post_event completed_event(email: "buyer@example.com", payment_intent: "pi_tier"),
        price_metadata: { "tier" => "forever" }
    end

    purchase = Purchase.order(:created_at).last
    assert_equal @product, purchase.product
    assert_equal "buyer@example.com", purchase.email
    assert purchase.forever?
    assert_equal "pi_tier", purchase.provider_order_id
  end

  test "a standard tier buys a year of updates" do
    post_event completed_event(payment_intent: "pi_std"), price_metadata: { "tier" => "standard" }
    purchase = Purchase.order(:created_at).last
    assert purchase.standard?
    assert_equal 1.year.from_now.to_date, purchase.updates_until
  end

  # The $89 SKU is a lifetime license AND a forever unlock, both declared on the price.
  # Fulfillment already reads update_policy off the price when the session doesn't carry
  # one, so the two systems agree from the same metadata.
  test "a price declaring lifetime mints a lifetime license and a forever purchase" do
    post_event completed_event(payment_intent: "pi_89", quantity: nil),
      price_metadata: { "seats" => "3", "update_policy" => "lifetime", "tier" => "forever" }

    license = License.order(:created_at).last
    assert_equal "lifetime", license.update_policy
    assert_nil license.expires_at, "a lifetime license never stops getting updates"
    assert_equal 3, license.max_activations
    assert Purchase.order(:created_at).last.forever?
  end

  test "a price with no tier records no purchase" do
    assert_difference "License.count", 1 do
      assert_no_difference "Purchase.count" do
        post_event completed_event(payment_intent: "pi_untiered")
      end
    end
  end

  test "a duplicate delivery records the purchase only once" do
    post_event completed_event(payment_intent: "pi_pdup"), price_metadata: { "tier" => "forever" }
    assert_no_difference "Purchase.count" do
      post_event completed_event(payment_intent: "pi_pdup"), price_metadata: { "tier" => "forever" }
    end
    assert_response :ok
  end

  test "a full refund stamps the purchase, and a partial one leaves it alone" do
    post_event completed_event(payment_intent: "pi_pref"), price_metadata: { "tier" => "forever" }
    purchase = Purchase.find_by!(provider_order_id: "pi_pref")

    post_event refunded_event(payment_intent: "pi_pref", amount: 1000, amount_refunded: 400)
    assert_nil purchase.reload.refunded_at

    post_event refunded_event(payment_intent: "pi_pref")
    assert purchase.reload.refunded_at
  end

  test "a chargeback revokes the license" do
    post_event completed_event(payment_intent: "pi_dispute")
    license = License.order(:created_at).last

    post_event dispute_event(payment_intent: "pi_dispute")
    assert_response :ok
    assert license.reload.refunded?
  end

  test "an unpaid session mints nothing — a delayed payment method can still fail" do
    assert_no_difference -> { License.count } do
      post_event completed_event(payment_status: "unpaid", payment_intent: "pi_async")
    end
    assert_response :ok # ack it, or Stripe retries a delivery that is behaving correctly
  end

  test "async_payment_succeeded fulfills the sale the unpaid session did not" do
    post_event completed_event(payment_status: "unpaid", payment_intent: "pi_async")
    assert_difference -> { License.count }, 1 do
      post_event completed_event(payment_status: "paid", payment_intent: "pi_async",
        type: "checkout.session.async_payment_succeeded")
    end
  end

  private
    def dispute_event(payment_intent:)
      { type: "charge.dispute.created", data: { object: { payment_intent: } } }.to_json
    end

    def refunded_event(payment_intent:, amount: 1000, amount_captured: nil, amount_refunded: 1000)
      { type: "charge.refunded",
        data: { object: { payment_intent:, amount:, amount_captured: amount_captured || amount,
                          amount_refunded: } } }.to_json
    end

    # name: nil omits the key, exactly as Stripe does when the Checkout Session
    # doesn't collect a name — the default here so most tests cover that path.
    def completed_event(email: "buyer@example.com", product_id: @product.id,
                        quantity: 1, payment_intent: "pi_test", renew_license_key: nil,
                        stripe_customer: "cus_buyer", amount_total: 2999, amount_subtotal: nil,
                        currency: "eur", name: nil,
                        type: "checkout.session.completed", payment_status: "paid")
      metadata = { licencio_product_id: product_id, quantity: quantity.to_s }
      metadata[:renew_license_key] = renew_license_key if renew_license_key
      customer_details = { email: }
      customer_details[:name] = name if name
      {
        type:,
        data: { object: {
          id: "cs_#{payment_intent}", # every real session has one; session_price needs it
          customer: stripe_customer,
          customer_details:,
          metadata:,
          payment_status:,
          payment_intent:,
          amount_total:,
          amount_subtotal: amount_subtotal || amount_total,
          currency:
        } }
      }.to_json
    end

    # The webhook now reads the purchased line item (for the unlock flow's `tier`), so every
    # delivery needs a price to read. Empty metadata is the default on purpose: that's
    # picmal, which sells licenses only and must never grow a purchase row.
    def post_event(payload, price_metadata: {})
      price = Struct.new(:id, :product, :metadata)
        .new("price_test", @product.stripe_product_id, price_metadata)
      line_items = Struct.new(:data).new([ Struct.new(:price).new(price) ])

      Stripe::Checkout::Session.stub(:list_line_items, line_items) do
        post "/webhooks/stripe/#{@product.id}", params: payload, headers: signed(payload)
      end
    end

    # CONTENT_TYPE json keeps the body byte-for-byte; form-encoding would break the signature.
    def signed(payload)
      ts  = Time.now.to_i
      sig = OpenSSL::HMAC.hexdigest("SHA256", @secret, "#{ts}.#{payload}")
      { "Stripe-Signature" => "t=#{ts},v1=#{sig}", "CONTENT_TYPE" => "application/json" }
    end
end
