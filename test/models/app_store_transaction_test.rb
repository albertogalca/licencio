require "test_helper"
require_relative "../support/app_store_signing"

class AppStoreTransactionTest < ActiveSupport::TestCase
  setup do
    @signing = AppStoreSigning.new
    AppStoreTransaction.trusted_root = @signing.root
  end

  teardown { AppStoreTransaction.trusted_root = nil }

  test "a transaction signed through the trusted chain parses into its fields" do
    transaction = AppStoreTransaction.verify(@signing.jws(AppStoreSigning.transaction("environment" => "Sandbox")))

    assert_equal "2000000111", transaction.original_transaction_id
    assert_equal "studio.cantimplora.cozy.lifetime", transaction.product_id
    assert_equal "studio.cantimplora.cozy", transaction.bundle_id
    assert_equal "sandbox", transaction.environment
    assert_equal 4999, transaction.amount_cents
    assert_equal "usd", transaction.currency
    assert_nil transaction.revocation_date
  end

  test "the vendored Apple root is the default trust anchor" do
    AppStoreTransaction.trusted_root = nil
    assert_equal "63343ABFB89A6A03EBB57E9B3F5FA7BE7C4F5C756F3017B3A8C488C3653E9179",
      OpenSSL::Digest::SHA256.hexdigest(AppStoreTransaction.trusted_root.to_der).upcase
    assert_raises(AppStoreTransaction::Invalid) { AppStoreTransaction.verify(@signing.jws) }
  end

  test "a payload altered after signing is refused" do
    header, _payload, signature = @signing.jws.split(".")
    forged = Base64.urlsafe_encode64(JSON.generate(AppStoreSigning.transaction("productId" => "x")), padding: false)
    assert_raises(AppStoreTransaction::Invalid) { AppStoreTransaction.verify([ header, forged, signature ].join(".")) }
  end

  test "a signature from a key other than the leaf's is refused" do
    jws = @signing.jws(AppStoreSigning.transaction, signing_key: OpenSSL::PKey::EC.generate("prime256v1"))
    assert_raises(AppStoreTransaction::Invalid) { AppStoreTransaction.verify(jws) }
  end

  test "a chain without Apple's markers is refused even when it reaches the root" do
    [ AppStoreSigning.new(leaf_oid: nil), AppStoreSigning.new(intermediate_oid: nil) ].each do |signing|
      AppStoreTransaction.trusted_root = signing.root
      assert_raises(AppStoreTransaction::Invalid) { AppStoreTransaction.verify(signing.jws) }
    end
  end

  test "garbage is refused, not raised" do
    [ nil, "", "a.b", "a.b.c", "#{Base64.urlsafe_encode64("[]")}.e30.AA" ].each do |jws|
      assert_raises(AppStoreTransaction::Invalid) { AppStoreTransaction.verify(jws) }
    end
  end

  test "only the Standard product of the same app grants anything, and never once revoked" do
    cozy = products(:cozy)
    grant = ->(**overrides) { AppStoreTransaction.verify(@signing.jws(AppStoreSigning.transaction(**overrides))).grant_for(cozy) }

    assert_equal "standard", grant.call[:tier]
    assert_nil grant.call("productId" => "studio.cantimplora.cozy.trial")
    assert_nil grant.call("bundleId" => "com.example.other")
    assert_nil grant.call("revocationDate" => (Time.current.to_f * 1000).to_i)
    assert_nil AppStoreTransaction.verify(@signing.jws).grant_for(products(:picmal))
  end
end
