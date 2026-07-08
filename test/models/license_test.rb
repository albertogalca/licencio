require "test_helper"

class LicenseTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  test "fixtures are valid" do
    assert licenses(:cozy_active).valid?
    assert licenses(:cozy_unclaimed).valid?
    assert licenses(:picmal_expired).valid?
  end

  test "requires license_key and status (max_activations nil = unlimited)" do
    license = License.new
    assert_not license.valid?
    assert_includes license.errors.attribute_names, :license_key
    assert_includes license.errors.attribute_names, :status
    assert_not_includes license.errors.attribute_names, :max_activations
  end

  test "a nil max_activations means unlimited seats" do
    license = products(:cozy).licenses.create!(status: "active", max_activations: nil)
    10.times { |i| license.activate!(hardware_id: "HW-#{i}") }
    assert_equal 10, license.activations.active.count # no cap
  end

  test "license_key is unique" do
    dup = licenses(:cozy_active).dup
    assert_not dup.valid?
    assert_includes dup.errors.attribute_names, :license_key
  end

  test "belongs to product and optionally to customer" do
    assert_equal products(:cozy), licenses(:cozy_active).product
    assert_equal customers(:alberto), licenses(:cozy_active).customer
    assert_nil licenses(:cozy_unclaimed).customer
    assert licenses(:cozy_unclaimed).valid?
  end

  test "status and migration_source enums" do
    assert licenses(:cozy_active).active?
    assert licenses(:picmal_expired).expired?
    assert licenses(:cozy_unclaimed).migration_source_lemon_squeezy?
  end

  test "has many activations, destroyed with the license" do
    license = licenses(:cozy_active)
    assert_equal 2, license.activations.count
    assert_difference "Activation.count", -2 do
      license.destroy
    end
  end

  test "generate_key uppercases the prefix and appends a UUID, unique each time" do
    key = License.generate_key(products(:picmal)) # license_prefix PICM -> PICM-<UUID>
    assert_match(/\APICM-[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\z/, key)
    assert_not_equal key, License.generate_key(products(:picmal))
  end

  test "assigns a native license_key on create" do
    license = products(:cozy).licenses.create!(status: "active", max_activations: 3)
    assert_match(/\ACOZY-[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\z/, license.license_key)
  end

  test "find_by_key looks up by exact string" do
    assert_equal licenses(:cozy_active), License.find_by_key("COZY-1111-2222-3333")
    assert_nil License.find_by_key("does-not-exist")
  end

  test "update_eligible? is always true for a lifetime product" do
    assert products(:cozy).lifetime?
    assert licenses(:cozy_active).update_eligible?
  end

  test "update_eligible? for time_limited tracks expires_at" do
    license = products(:picmal).licenses.create!(status: "active", max_activations: 5,
      expires_at: 30.days.from_now)
    assert license.update_eligible?, "inside the window"

    license.update!(expires_at: 1.day.ago)
    assert_not license.update_eligible?, "past expiry, updates cut off"
  end

  test "renewing a time_limited license restores update eligibility (H1)" do
    license = products(:picmal).licenses.create!(status: "active", max_activations: 5,
      expires_at: 1.day.ago) # expired: updates cut off
    assert_not license.update_eligible?

    license.renew!(stripe_payment_id: "pi_renew_1")
    assert license.expires_at.future?, "renewal pushes expiry out"
    assert license.update_eligible?, "and updates are restored"
  end

  test "per-license policy overrides the product's" do
    license = licenses(:cozy_active) # product cozy is lifetime
    license.update!(update_policy: "versioned", licensed_version: 1)
    assert_equal "versioned", license.effective_update_policy
  end

  test "versioned license is eligible until the product outgrows its version" do
    license = products(:cozy).licenses.create!(status: "active", max_activations: 3,
      update_policy: "versioned", licensed_version: 1)
    assert license.update_eligible?, "v1 license, product still on v1"

    license.product.update!(current_version: 2)
    assert_not license.reload.update_eligible?, "product moved to v2, v1 license excluded"

    license.update!(licensed_version: 2) # paid v2 upgrade
    assert license.update_eligible?, "bumped to v2, eligible again"
  end

  test "lifetime override stays eligible regardless of product version" do
    license = products(:cozy).licenses.create!(status: "active", max_activations: 3,
      update_policy: "lifetime")
    license.product.update!(current_version: 5)
    assert license.update_eligible?
  end

  test "a versioned override requires a licensed_version snapshot" do
    license = products(:cozy).licenses.new(status: "active", max_activations: 3,
      update_policy: "versioned")
    assert_not license.valid?
    assert_includes license.errors.attribute_names, :licensed_version

    license.licensed_version = 1
    assert license.valid?
  end

  test "import creates an unclaimed license when the row has no email" do
    rows = [ { product_slug: products(:cozy).slug, license_key: "COZY-NO-EMAIL" } ]
    result = License.import(rows, source: "polar")
    assert_equal 1, result[:imported]
    assert_nil License.find_by_key("COZY-NO-EMAIL").customer
  end

  test "import carries per-license update_policy and licensed_version" do
    rows = [
      { product_slug: products(:cozy).slug, license_key: "COZY-V1", licensed_version: "1" },
      { product_slug: products(:cozy).slug, license_key: "COZY-LIFETIME", update_policy: "lifetime" }
    ]
    assert_equal 2, License.import(rows, source: "polar")[:imported]

    v1 = License.find_by_key("COZY-V1") # inherits product's versioned policy, snapshot pins eligibility
    assert_equal 1, v1.licensed_version
    assert v1.update_eligible?

    assert_equal "lifetime", License.find_by_key("COZY-LIFETIME").update_policy
  end

  test "issue_license! maps a lifetime price to a lifetime license; default inherits versioned" do
    prod = Product.create!(name: "Versioned", slug: "vp", bundle_identifier: "com.x.vp",
      license_prefix: "VP", update_policy: "versioned", current_version: 2)

    lifetime = prod.issue_license!(customer: nil, quantity: nil, stripe_payment_id: "pi_lf", update_policy: "lifetime")
    assert_equal "lifetime", lifetime.update_policy
    assert_nil lifetime.licensed_version # lifetime ignores version snapshot
    assert_nil lifetime.max_activations  # nil quantity = unlimited, not 0 seats
    assert lifetime.update_eligible?

    default = prod.issue_license!(customer: nil, quantity: nil, stripe_payment_id: "pi_v")
    assert_nil default.update_policy      # inherits product default
    assert_equal 2, default.licensed_version # pinned to current_version
  end

  test "resendable_emails reflects the license's state" do
    license = licenses(:cozy_active) # lifetime, claimed, no payment
    assert_equal [ "portal" ], license.resendable_emails

    license.payments.create!(stripe_payment_intent: "pi_r", kind: "purchase")
    assert_includes license.resendable_emails, "purchase"

    assert_includes licenses(:picmal_expired).resendable_emails, "expiry" # time_limited w/ expires_at

    refunded = products(:cozy).licenses.create!(status: "refunded", max_activations: 1, customer: customers(:alberto))
    assert_includes refunded.resendable_emails, "refund"

    assert_empty licenses(:cozy_unclaimed).resendable_emails, "no customer, nothing to send"
  end

  test "redeliver_email_later clears the dedup and re-enqueues, reconstructing purchase amount" do
    license = licenses(:cozy_active)
    license.payments.create!(stripe_payment_intent: "pi_amt", kind: "purchase", amount_cents: 4999, currency: "eur")
    # A prior send is recorded — without clearing, Notification.once would suppress the resend.
    Notification.create!(customer: license.customer, kind: "purchase", reference_id: license.id, sent_at: Time.current)

    assert_enqueued_with(job: LicenseEmailJob) do
      assert license.redeliver_email_later("purchase")
    end
    assert_empty Notification.where(customer_id: license.customer_id, kind: "purchase", reference_id: license.id),
      "the sent-marker is cleared so the resend actually goes out"
    data = enqueued_jobs.find { |j| j["job_class"] == "LicenseEmailJob" }["arguments"].last["data"]
    assert_equal "49.99 EUR", data[:amount] || data["amount"]
  end

  test "redeliver_email_later portal enqueues a fresh access link" do
    assert_enqueued_with(job: PortalAccessJob) do
      assert licenses(:cozy_active).redeliver_email_later("portal")
    end
  end

  test "redeliver_email_later refuses an unclaimed license or an inapplicable kind" do
    assert_nil licenses(:cozy_unclaimed).redeliver_email_later("portal"), "no customer"
    assert_nil licenses(:cozy_active).redeliver_email_later("refund"), "not refunded → not applicable"
  end

  test "activate! is idempotent and enforces capacity" do
    license = products(:cozy).licenses.create!(status: "active", max_activations: 1)
    a = license.activate!(hardware_id: "HW-X")
    assert_equal a, license.activate!(hardware_id: "HW-X") # same seat, no new row
    assert_raises(License::CapacityExceeded) { license.activate!(hardware_id: "HW-Y") }
  end

  test "real activation evicts an LS placeholder seat, then the cap bites" do
    license = products(:cozy).licenses.create!(status: "active", max_activations: 2)
    license.import_provisional_activation!(hardware_id: "ls-1", device_name: "Mac A", activated_at: 2.days.ago)
    license.import_provisional_activation!(hardware_id: "ls-2", device_name: "Mac B", activated_at: 1.day.ago)
    assert_equal 2, license.activations.active.count

    license.activate!(hardware_id: "HW-REAL-1") # evicts oldest placeholder (ls-1)
    assert_equal 1, license.activations.active.provisional.count
    assert license.activations.active.find_by(hardware_id: "HW-REAL-1")

    license.activate!(hardware_id: "HW-REAL-2") # evicts the last placeholder (ls-2)
    assert_equal 0, license.activations.active.provisional.count
    assert_equal 2, license.activations.active.count

    # No placeholder left — a real device never evicts another real device.
    assert_raises(License::CapacityExceeded) { license.activate!(hardware_id: "HW-REAL-3") }
    assert license.activations.active.find_by(hardware_id: "HW-REAL-2")
  end

  test "import_provisional_activation! is idempotent and respects the cap" do
    license = products(:cozy).licenses.create!(status: "active", max_activations: 1)
    license.import_provisional_activation!(hardware_id: "ls-1", device_name: "Mac A", activated_at: 1.day.ago)
    license.import_provisional_activation!(hardware_id: "ls-1", device_name: "Mac A", activated_at: 1.day.ago) # re-run
    license.import_provisional_activation!(hardware_id: "ls-2", device_name: "Mac B", activated_at: 1.day.ago) # over cap
    assert_equal 1, license.activations.active.count
  end

  test "renew! is idempotent — a duplicate payment id does not extend twice" do
    license = products(:picmal).licenses.create!(status: "active", max_activations: 5) # 365-day window
    license.renew!(stripe_payment_id: "pi_renew")
    first_expiry = license.reload.expires_at

    license.renew!(stripe_payment_id: "pi_renew") # same event redelivered
    assert_equal first_expiry.to_i, license.reload.expires_at.to_i, "second identical renewal is a no-op"
  end

  test "expire_overdue! flips only past-due active licenses to expired" do
    overdue = products(:cozy).licenses.create!(status: "active", max_activations: 1, expires_at: 1.hour.ago)
    future  = products(:cozy).licenses.create!(status: "active", max_activations: 1, expires_at: 1.hour.from_now)
    lifetime = licenses(:cozy_active) # no expires_at

    assert_equal 1, License.expire_overdue!
    assert overdue.reload.expired?
    assert future.reload.active?
    assert lifetime.reload.active?
  end

  test "activatable? requires active status and a live (or absent) expiry" do
    active = products(:cozy).licenses.create!(status: "active", max_activations: 1)
    assert active.activatable?

    active.update!(expires_at: 1.day.ago)
    assert_not active.activatable?, "expired-but-active must not be activatable"

    active.update!(expires_at: 1.day.from_now)
    assert active.activatable?
  end

  test "token_claims carries a 7-day exp lease, even for a lifetime (no-expiry) license" do
    lifetime = licenses(:cozy_active) # no expires_at
    claims = lifetime.token_claims(hardware_id: "HW-1", nonce: "n")

    assert_nil claims[:expires_at], "lifetime license has no license-level expiry"
    assert_in_delta 7.days.from_now.to_i, claims[:exp], 1.hour, "token still gets a lease"
    assert claims[:exp] > claims[:iat]
  end

  test "deactivate! frees the seat" do
    license = products(:cozy).licenses.create!(status: "active", max_activations: 1)
    license.activate!(hardware_id: "HW-X")
    assert license.deactivate!(hardware_id: "HW-X")
    assert_nil license.deactivate!(hardware_id: "HW-X") # already released
    assert license.activate!(hardware_id: "HW-Y") # slot is free again
  end

  test "renewable? only for a time_limited Stripe license that is expired or expiring soon" do
    p = products(:picmal) # time_limited, stripe-enabled
    expired   = p.licenses.create!(status: "expired", customer: customers(:alberto), max_activations: 1, expires_at: 1.day.ago)
    soon      = p.licenses.create!(status: "active",  customer: customers(:alberto), max_activations: 1, expires_at: 10.days.from_now)
    far       = p.licenses.create!(status: "active",  customer: customers(:alberto), max_activations: 1, expires_at: 300.days.from_now)
    no_expiry = p.licenses.create!(status: "active",  customer: customers(:alberto), max_activations: 1, expires_at: nil)

    assert expired.renewable?
    assert soon.renewable?
    assert_not far.renewable?, "a freshly renewed license far from expiry should not show renew"
    assert_not no_expiry.renewable?
    # Lifetime product never renews.
    assert_not licenses(:cozy_active).renewable?
  end

  test "remind_expiring! enqueues a reminder for licenses expiring in the target window" do
    license = products(:picmal).licenses.create!(status: "active", customer: customers(:alberto),
      max_activations: 1, expires_at: 7.days.from_now)
    assert_enqueued_with(job: LicenseEmailJob) do
      License.remind_expiring!(days: 7)
    end
  end

  test "remind_expiring! ignores lifetime, already-expired, and out-of-window licenses" do
    p = products(:picmal)
    p.licenses.create!(status: "active", customer: customers(:alberto), max_activations: 1) # lifetime (nil expires_at)
    p.licenses.create!(status: "expired", customer: customers(:alberto), max_activations: 1, expires_at: 7.days.from_now)
    p.licenses.create!(status: "active", customer: customers(:alberto), max_activations: 1, expires_at: 30.days.from_now)
    assert_no_enqueued_jobs only: LicenseEmailJob do
      License.remind_expiring!(days: 7)
    end
  end

  test "fulfill_from_stripe_session (Payment Link): no metadata — derives seats + product from the price" do
    product = products(:picmal)
    price = fake_stripe_price("price_pl", product.stripe_product_id, { "seats" => "3" })
    session = fake_session(metadata: {}, id: "cs_pl")
    stub_line_item(price) do
      assert_difference "License.count", 1 do
        license = License.fulfill_from_stripe_session(product, session)
        assert_equal 3, license.max_activations
        assert_equal product, license.product
        assert_equal "price_pl", license.stripe_price_id
      end
    end
  end

  test "fulfill_from_stripe_session (dynamic): trusts session metadata without calling Stripe" do
    product = products(:picmal)
    # No list_line_items stub — a Stripe call here would raise and fail the test.
    session = fake_session(metadata: { licencio_product_id: product.id, quantity: "2", price_id: "price_dyn" }, id: "cs_dyn")
    license = License.fulfill_from_stripe_session(product, session)
    assert_equal 2, license.max_activations
    assert_equal "price_dyn", license.stripe_price_id
  end

  test "fulfill_from_stripe_session ignores a sale whose price belongs to another Stripe product" do
    product = products(:picmal)
    price = fake_stripe_price("price_x", "prod_SOMEONE_ELSE", { "seats" => "1" })
    session = fake_session(metadata: {}, id: "cs_other")
    stub_line_item(price) do
      assert_no_difference "License.count" do
        assert_nil License.fulfill_from_stripe_session(product, session)
      end
    end
  end

  test "fulfill_from_stripe_session refuses to mint when no seat count is declared anywhere" do
    product = products(:picmal)
    product.update!(max_activations_default: nil)
    price = fake_stripe_price("price_noseat", product.stripe_product_id, {})
    session = fake_session(metadata: {}, id: "cs_noseat")
    stub_line_item(price) do
      assert_raises(Product::CheckoutNotConfigured) { License.fulfill_from_stripe_session(product, session) }
    end
  end

  private
    def fake_session(metadata:, id:)
      meta = Struct.new(:licencio_product_id, :quantity, :price_id, :update_policy, :renew_license_key,
        keyword_init: true).new(**metadata)
      Struct.new(:metadata, :id, :customer_details, :payment_intent, :customer, :amount_total, :currency,
        keyword_init: true).new(metadata: meta, id:, customer_details: Struct.new(:email).new("buyer-#{id}@example.com"),
        payment_intent: "pi_#{id}", customer: "cus_#{id}", amount_total: 1599, currency: "usd")
    end

    def fake_stripe_price(id, product, metadata)
      Struct.new(:id, :product, :metadata).new(id, product, metadata)
    end

    def stub_line_item(price, &blk)
      list = Struct.new(:data).new([ Struct.new(:price).new(price) ])
      Stripe::Checkout::Session.stub(:list_line_items, ->(*_) { list }, &blk)
    end
end
