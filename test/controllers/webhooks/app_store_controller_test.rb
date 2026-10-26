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
end
