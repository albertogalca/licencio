require "test_helper"
require_relative "../../support/app_store_signing"

class V1::IapClaimsTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @product = products(:cozy)
    @product.update!(purchase_transactional_id: "tmpl_cozy_purchase", update_duration_days: 365,
      loops_mailing_list_id: "list_cozy_news")
    @signing = AppStoreSigning.new
    AppStoreTransaction.trusted_root = @signing.root
    @sent_to = []
    @contacts = []
  end

  teardown { AppStoreTransaction.trusted_root = nil }

  def claim(email: "ana@example.com", jws: @signing.jws, slug: @product.slug, **extra)
    Loops.stub :send_transactional, ->(email:, **) { @sent_to << email } do
      Loops.stub :upsert_contact, ->(**contact) { @contacts << contact.slice(:email, :subscribed, :mailing_lists) } do
        perform_enqueued_jobs do
          post "/v1/iap/claim", params: { product_slug: slug, email:, jws:, **extra }, as: :json
        end
      end
    end
  end

  def claim_records = [ License, Purchase, Payment, Customer ].map(&:count)

  test "a first claim mints the Standard license and mails its key" do
    assert_difference -> { @product.licenses.count } => 1, -> { @product.purchases.count } => 1 do
      claim(email: " ana@example.com ")
    end

    assert_response :ok
    assert_equal({ "ok" => true }, response.parsed_body)

    license = @product.licenses.find_by!(app_store_original_transaction_id: "2000000111")
    assert_equal "ana@example.com", license.customer.email
    assert_equal "time_limited", license.effective_update_policy
    assert_nil license.max_activations, "unlimited seats, as on the Stripe Standard price"
    assert_in_delta 365.days.from_now, license.expires_at, 1.minute
    assert license.app_store_production?
    assert_equal [ [ "purchase", 4999, "usd" ] ], license.payments.pluck(:kind, :amount_cents, :currency)

    purchase = @product.purchases.find_by!(provider: "app_store", provider_order_id: "2000000111")
    assert_equal [ "standard", "ana@example.com", 1.year.from_now.to_date ],
      [ purchase.tier, purchase.email, purchase.updates_until ]

    assert_equal [ "ana@example.com" ], @sent_to
  end

  test "claiming the same purchase again mints nothing and mails the first address only" do
    claim(email: "ana@example.com")
    first_response = response.parsed_body
    later_purchase = @signing.jws(AppStoreSigning.transaction("transactionId" => "2000000999"))

    assert_no_changes -> { claim_records } do
      claim(email: "someone.else@example.com", jws: later_purchase)
    end

    assert_response :ok
    assert_equal first_response, response.parsed_body, "a repeat claim looks like a first one"
    assert_equal [ "ana@example.com", "ana@example.com" ], @sent_to
  end

  test "a claim with newsletter true adds the buyer to the product's mailing list" do
    claim(newsletter: true)

    assert_response :ok
    assert_equal [ { email: "ana@example.com", subscribed: true, mailing_lists: { "list_cozy_news" => true } } ],
      @contacts
  end

  test "a claim without a JSON true for newsletter upserts the buyer unsubscribed, with no mailing list" do
    { "absent" => {}, "false" => { newsletter: false }, "string" => { newsletter: "true" },
      "number" => { newsletter: 1 } }.each_with_index do |(label, extra), index|
      @contacts.clear
      claim(jws: @signing.jws(AppStoreSigning.transaction("originalTransactionId" => "300000000#{index}")), **extra)

      assert_response :ok, label
      assert_equal [ { email: "ana@example.com", subscribed: false, mailing_lists: nil } ], @contacts, label
    end
  end

  test "a repeat claim with newsletter true adds the first claimant, and false touches no contact" do
    claim(email: "ana@example.com")
    @contacts.clear

    claim(email: "someone.else@example.com", newsletter: false)
    assert_empty @contacts, "a repeat claim without consent never changes a contact"

    claim(email: "someone.else@example.com", newsletter: true)
    assert_equal [ { email: "ana@example.com", subscribed: true, mailing_lists: { "list_cozy_news" => true } } ],
      @contacts
  end

  test "a transaction this server will not honour is refused and records nothing" do
    stranger = AppStoreSigning.new
    refused = {
      "wrong bundle id" => @signing.jws(AppStoreSigning.transaction("bundleId" => "com.example.other")),
      "wrong product id" => @signing.jws(AppStoreSigning.transaction("productId" => "studio.cantimplora.cozy.trial")),
      "revoked" => @signing.jws(AppStoreSigning.transaction("revocationDate" => (Time.current.to_f * 1000).to_i)),
      "bad signature" => @signing.jws(AppStoreSigning.transaction,
        signing_key: OpenSSL::PKey::EC.generate("prime256v1")),
      "untrusted chain" => stranger.jws,
      "not a JWS" => "garbage"
    }

    refused.each do |reason, jws|
      assert_no_changes -> { claim_records }, reason do
        claim(jws:)
      end
      assert_response :unprocessable_entity, reason
      assert_equal "transaction_invalid", response.parsed_body["code"], reason
    end
    assert_empty @sent_to
  end

  test "an address that is not one is refused before the transaction is looked at" do
    assert_no_changes -> { claim_records } do
      claim(email: "not-an-address")
    end
    assert_response :unprocessable_entity
    assert_equal "invalid_email", response.parsed_body["code"]
  end

  test "a Sandbox purchase is accepted and recorded as Sandbox" do
    claim(jws: @signing.jws(AppStoreSigning.transaction("environment" => "Sandbox")))

    assert_response :ok
    assert @product.licenses.find_by!(app_store_original_transaction_id: "2000000111").app_store_sandbox?
  end

  test "the app's preflight is answered with open CORS" do
    process :options, "/v1/iap/claim"
    assert_response :no_content
    assert_equal "*", response.headers["Access-Control-Allow-Origin"]
  end
end
