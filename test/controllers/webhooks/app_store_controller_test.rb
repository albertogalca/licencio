require "test_helper"
require_relative "../../support/app_store_signing"

class Webhooks::AppStoreControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @product = products(:cozy)
    @product.update!(purchase_transactional_id: "tmpl_cozy_purchase", update_duration_days: 365)
    @signing = AppStoreSigning.new
    AppStoreTransaction.trusted_root = @signing.root
  end

  teardown { AppStoreTransaction.trusted_root = nil }

  def claim
    Loops.stub :send_transactional, ->(**) { } do
      Loops.stub :upsert_contact, ->(**) { } do
        perform_enqueued_jobs do
          post "/v1/iap/claim", params: { product_slug: @product.slug, email: "ana@example.com", jws: @signing.jws },
            as: :json
        end
      end
    end
    assert_response :ok
    clear_enqueued_jobs
  end

  def notify(signed_payload, product_id: @product.id)
    post "/webhooks/app_store/#{product_id}", params: { signedPayload: signed_payload }, as: :json
  end

  def license = @product.licenses.find_by!(app_store_original_transaction_id: "2000000111")
  def purchase = @product.purchases.find_by!(provider: "app_store", provider_order_id: "2000000111")

  %w[REFUND REVOKE].each do |type|
    test "a #{type} revokes the claimed license and its unlock purchase" do
      claim

      assert_enqueued_jobs 1, only: LicenseEmailJob do
        notify @signing.notification(type)
      end

      assert_response :ok
      assert license.refunded?
      assert_not_nil purchase.refunded_at
      assert_empty Purchase.live.for_email(@product, "ana@example.com"), "the unlock flow no longer finds it"
    end
  end

  test "a redelivered REFUND revokes once and mails no second refund email" do
    claim

    assert_enqueued_jobs 1, only: LicenseEmailJob do
      notify @signing.notification("REFUND")
      notify @signing.notification("REFUND")
    end
    assert_response :ok
    assert license.refunded?
  end

  test "a notification signed through a stranger's chain is refused and changes nothing" do
    claim

    notify AppStoreSigning.new.notification("REFUND")

    assert_response :bad_request
    assert license.active?
    assert_nil purchase.refunded_at
  end

  test "a notification that is not a JWS is refused" do
    notify "garbage"
    assert_response :bad_request
  end

  test "any other notification is acknowledged and changes nothing" do
    claim

    notify @signing.notification("CONSUMPTION_REQUEST")

    assert_response :ok
    assert license.active?
    assert_nil purchase.refunded_at
  end

  test "a REFUND of another app's purchase is acknowledged and leaves this product's license" do
    claim
    other_app = AppStoreSigning.transaction("bundleId" => "com.example.other",
      "revocationDate" => (Time.current.to_f * 1000).to_i)

    notify @signing.notification("REFUND", other_app)

    assert_response :ok
    assert license.active?
    assert_nil purchase.refunded_at
  end

  test "a REFUND sent to another product's endpoint does not revoke this product's license" do
    claim

    notify @signing.notification("REFUND"), product_id: products(:picmal).id

    assert_response :ok
    assert license.active?
  end

  test "an unknown product is not found" do
    notify @signing.notification("REFUND"), product_id: SecureRandom.uuid
    assert_response :not_found
  end

  def unlock(**overrides)
    AppStoreSigning.transaction("transactionId" => "2000000500", "originalTransactionId" => "2000000500",
      "bundleId" => "com.example.myapp", "productId" => "com.example.myapp.unlock",
      "appTransactionId" => "705000000000001", "price" => 19990, **overrides)
  end

  def ms(time) = (time.to_f * 1000).to_i

  test "a ONE_TIME_CHARGE records the charge with the buyer's app transaction id" do
    purchased_at = Time.utc(2026, 11, 3, 9, 30)

    notify @signing.notification("ONE_TIME_CHARGE", unlock("purchaseDate" => ms(purchased_at)))

    assert_response :ok
    charge = @product.app_store_charges.sole
    assert_equal [ "com.example.myapp.unlock", "2000000500", "2000000500", "705000000000001", "com.example.myapp" ],
      [ charge.store_product_id, charge.transaction_id, charge.original_transaction_id,
        charge.app_transaction_id, charge.bundle_id ]
    assert_equal [ "production", purchased_at, 1999, "usd", "USA" ],
      [ charge.environment, charge.purchased_at, charge.amount_cents, charge.currency, charge.storefront ]
    assert_nil charge.revoked_at
  end

  test "a redelivered ONE_TIME_CHARGE leaves one charge" do
    2.times do
      notify @signing.notification("ONE_TIME_CHARGE", unlock)
      assert_response :ok
    end

    assert_equal 1, AppStoreCharge.count
  end

  test "a ONE_TIME_CHARGE without an app transaction id records the charge without one" do
    notify @signing.notification("ONE_TIME_CHARGE", unlock.except("appTransactionId"))

    assert_response :ok
    assert_nil @product.app_store_charges.sole.app_transaction_id
  end

  %w[REFUND REVOKE].each do |type|
    test "a #{type} marks the recorded charge revoked" do
      revoked_at = Time.utc(2026, 11, 10, 8)
      notify @signing.notification("ONE_TIME_CHARGE", unlock)

      notify @signing.notification(type, unlock("revocationDate" => ms(revoked_at)))

      assert_response :ok
      assert_equal revoked_at, @product.app_store_charges.sole.revoked_at
    end
  end

  test "a REFUND sent to another product's endpoint leaves this product's charge unrevoked" do
    notify @signing.notification("ONE_TIME_CHARGE", unlock)

    notify @signing.notification("REFUND", unlock("revocationDate" => ms(Time.current))),
      product_id: Product.where.not(id: @product.id).first.id

    assert_nil @product.app_store_charges.sole.revoked_at
  end

  test "notifications other than a one-time charge record nothing" do
    %w[REFUND CONSUMPTION_REQUEST REFUND_DECLINED REFUND_REVERSED TEST].each do |type|
      notify @signing.notification(type, unlock)
      assert_response :ok
    end

    assert_equal 0, AppStoreCharge.count
  end
end
