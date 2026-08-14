require "test_helper"

class PurchaseTest < ActiveSupport::TestCase
  setup { @product = products(:cozy) }

  # The spellings that must collapse to one inbox, and the ones that must NOT. Getting
  # either direction wrong is a customer who paid and can't unlock, or one who unlocks
  # something they didn't buy.
  test "gmail dots and +tags collapse to one address" do
    assert_equal "anaperez@gmail.com", Purchase.normalize_email("Ana.Perez+cozy@Gmail.com")
    assert_equal "anaperez@gmail.com", Purchase.normalize_email("anaperez@gmail.com")
    assert_equal "anaperez@googlemail.com", Purchase.normalize_email("a.na.perez+x@GoogleMail.com")
  end

  test "dots are significant everywhere except Google" do
    assert_equal "a.n.a@fastmail.com", Purchase.normalize_email("A.N.A@Fastmail.com")
    assert_not_equal Purchase.normalize_email("ana@fastmail.com"),
      Purchase.normalize_email("a.n.a@fastmail.com")
  end

  test "+tags are stripped for every provider" do
    assert_equal "bob@corp.com", Purchase.normalize_email("bob+cozy@corp.com")
  end

  # If Ruby and Postgres ever disagree, the row is in the table and the lookup can't see it.
  # Every input here goes through both sides and has to come out the same.
  test "normalize_email matches the SQL expression exactly" do
    raws = [
      "alberto@example.com", "Alberto@EXAMPLE.com", "  spaced@example.com  ",
      "Ana.Perez+cozy@Gmail.com", "anaperez@gmail.com", "a.n.a+x@googlemail.com",
      "dots.matter@fastmail.com", "plus+one+two@fastmail.com", "UPPER+TAG@GMAIL.COM",
      "weird@@example.com", "noatsign", "@nolocal.com", "+tag@gmail.com"
    ]

    raws.each do |raw|
      purchase = Purchase.create!(product: @product, email: raw, tier: "forever",
        purchased_at: Time.current, provider: "test", provider_order_id: "parity:#{raw}")
      from_sql = Purchase.where(id: purchase.id)
        .pick(Arel.sql(Purchase::NORMALIZED_EMAIL_SQL))
      assert_equal Purchase.normalize_email(raw), from_sql, "disagreement for #{raw.inspect}"
    end
  end

  test "for_email finds a purchase however the buyer spells it" do
    purchase = purchases(:cozy_forever) # stored as Ana.Perez+cozy@Gmail.com
    [ "anaperez@gmail.com", "ANAPEREZ@gmail.com", "ana.perez@gmail.com",
      " Ana.Perez+anything@Gmail.com " ].each do |spelling|
      assert_equal [ purchase ], Purchase.for_email(@product, spelling).to_a, spelling
    end

    # googlemail collapses like gmail, but it's still a different domain to a different row.
    assert_empty Purchase.for_email(@product, "anaperez@googlemail.com")
  end

  test "for_email is scoped to the product" do
    assert_empty Purchase.for_email(products(:picmal), "anaperez@gmail.com")
  end

  test "live excludes refunded purchases" do
    assert_not_includes Purchase.live, purchases(:cozy_refunded)
    assert_includes Purchase.live, purchases(:cozy_forever)
  end

  test "record_stripe! writes a standard purchase with a year of updates" do
    purchase = Purchase.record_stripe!(@product, session(payment_intent: "pi_std"),
      price: price("tier" => "standard"))

    assert purchase.standard?
    assert_equal "buyer@example.com", purchase.email
    assert_equal "pi_std", purchase.provider_order_id
    assert_equal "stripe", purchase.provider
    assert_equal 1.year.from_now.to_date, purchase.updates_until
    assert_equal %w[mac windows iphone], purchase.platforms
  end

  test "record_stripe! writes a forever purchase with no update deadline" do
    purchase = Purchase.record_stripe!(@product, session(payment_intent: "pi_fvr"),
      price: price("tier" => "forever"))

    assert purchase.forever?
    assert_nil purchase.updates_until
  end

  # picmal sells through the same webhook and must not grow purchase rows.
  test "record_stripe! records nothing for a price with no tier metadata" do
    assert_no_difference "Purchase.count" do
      assert_nil Purchase.record_stripe!(@product, session, price: price({}))
      assert_nil Purchase.record_stripe!(@product, session, price: price("tier" => "bogus"))
      assert_nil Purchase.record_stripe!(@product, session, price: nil)
    end
  end

  test "record_stripe! is idempotent under Stripe's redelivery" do
    Purchase.record_stripe!(@product, session(payment_intent: "pi_dup"), price: price("tier" => "standard"))
    assert_no_difference "Purchase.count" do
      Purchase.record_stripe!(@product, session(payment_intent: "pi_dup"), price: price("tier" => "forever"))
    end
    assert Purchase.find_by(provider_order_id: "pi_dup").standard?, "the first record wins"
  end

  test "record_stripe! refuses a session addressed to another product" do
    assert_no_difference "Purchase.count" do
      assert_nil Purchase.record_stripe!(@product,
        session(metadata: { "licencio_product_id" => products(:picmal).id }),
        price: price("tier" => "forever"))
    end
  end

  test "record_stripe! falls back to the session id when there is no payment intent" do
    purchase = Purchase.record_stripe!(@product, session(payment_intent: nil, id: "cs_only"),
      price: price("tier" => "forever"))
    assert_equal "cs_only", purchase.provider_order_id
  end

  test "refund! stamps the purchase once and ignores redeliveries" do
    purchase = purchases(:cozy_standard)
    Purchase.refund!(product: @product, provider_order_id: purchase.provider_order_id)
    stamped = purchase.reload.refunded_at
    assert stamped

    Purchase.refund!(product: @product, provider_order_id: purchase.provider_order_id)
    assert_equal stamped, purchase.reload.refunded_at
  end

  test "refund! ignores an unknown order and another product's order" do
    assert_nil Purchase.refund!(product: @product, provider_order_id: "pi_nope")
    assert_nil Purchase.refund!(product: products(:picmal), provider_order_id: "pi_cozy_standard")
    assert_nil purchases(:cozy_standard).reload.refunded_at
  end

  test "token_claims are permanent — no exp, ever" do
    claims = purchases(:cozy_standard).token_claims(device_id: "device-1")

    assert_equal 1, claims[:v]
    assert_equal purchases(:cozy_standard).id, claims[:sub]
    assert_equal "standard", claims[:tier]
    assert_equal "device-1", claims[:device]
    assert_not_includes claims.keys, :exp
  end

  # ── Backfill ─────────────────────────────────────────────────────────────────

  test "backfill turns a lifetime license into a forever purchase" do
    Purchase.backfill_from_licenses!(products(:cozy)) # cozy's policy is lifetime
    purchase = Purchase.find_by(provider_order_id: "license:#{licenses(:cozy_active).license_key}")

    assert purchase.forever?
    assert_nil purchase.updates_until
    assert_equal customers(:alberto).email, purchase.email
    assert_equal licenses(:cozy_active).claimed_at.to_i, purchase.purchased_at.to_i
  end

  test "backfill turns a dated license into a standard purchase" do
    Purchase.backfill_from_licenses!(products(:picmal)) # time_limited, expired fixture
    purchase = Purchase.find_by(provider_order_id: "license:#{licenses(:picmal_expired).license_key}")

    assert purchase.standard?
    assert_equal licenses(:picmal_expired).expires_at.to_date, purchase.updates_until
  end

  test "backfill marks a refunded license refunded and skips trials and unclaimed imports" do
    licenses(:cozy_active).update!(status: "refunded")
    counts = Purchase.backfill_from_licenses!(products(:cozy))

    purchase = Purchase.find_by(provider_order_id: "license:#{licenses(:cozy_active).license_key}")
    assert purchase.refunded_at
    # cozy_unclaimed has no customer, so it never reaches the tally at all.
    assert_equal 1, counts[:created]
  end

  test "backfill is idempotent and its dry run writes nothing" do
    assert_equal 1, Purchase.backfill_from_licenses!(products(:cozy))[:created]

    assert_no_difference "Purchase.count" do
      assert_equal 1, Purchase.backfill_from_licenses!(products(:cozy))[:existing]
      assert_equal 1, Purchase.backfill_from_licenses!(products(:cozy), dry_run: true)[:existing]
    end
  end

  test "backfill dry run counts what it would create without touching the table" do
    assert_no_difference "Purchase.count" do
      assert_equal 1, Purchase.backfill_from_licenses!(products(:cozy), dry_run: true)[:created]
    end
  end

  test "backfill prefers a real Stripe payment id over the license key" do
    licenses(:cozy_active).update!(stripe_payment_id: "pi_backfilled")
    Purchase.backfill_from_licenses!(products(:cozy))
    assert Purchase.exists?(provider: "stripe", provider_order_id: "pi_backfilled")
  end

  private
    def session(payment_intent: "pi_test", id: "cs_test", email: "buyer@example.com", metadata: {})
      Struct.new(:id, :payment_intent, :customer_details, :metadata)
        .new(id, payment_intent, Struct.new(:email).new(email), metadata)
    end

    def price(metadata) = Struct.new(:id, :metadata).new("price_test", metadata)
end
