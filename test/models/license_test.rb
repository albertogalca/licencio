require "test_helper"

class LicenseTest < ActiveSupport::TestCase
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

  test "generate_key uses a downcased prefix and is unique" do
    key = License.generate_key(products(:picmal))
    assert_match(/\Apicm_[a-z0-9]+\z/, key) # license_prefix PICM -> picm_
    assert_not_equal key, License.generate_key(products(:picmal))
  end

  test "assigns a native license_key on create" do
    license = products(:cozy).licenses.create!(status: "active", max_activations: 3)
    assert_match(/\Acozy_[a-z0-9]+\z/, license.license_key)
  end

  test "find_by_key looks up by exact string" do
    assert_equal licenses(:cozy_active), License.find_by_key("COZY-1111-2222-3333")
    assert_nil License.find_by_key("does-not-exist")
  end

  test "update_eligible? is always true for a lifetime product" do
    assert products(:cozy).lifetime?
    assert licenses(:cozy_active).update_eligible?
  end

  test "update_eligible? for time_limited depends on the update window" do
    license = products(:picmal).licenses.create!(status: "active", max_activations: 5) # 365-day window
    assert license.update_eligible?, "fresh license is inside the window"

    license.update!(claimed_at: 400.days.ago)
    assert_not license.update_eligible?, "past the 365-day window"
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

  test "activate! is idempotent and enforces capacity" do
    license = products(:cozy).licenses.create!(status: "active", max_activations: 1)
    a = license.activate!(hardware_id: "HW-X")
    assert_equal a, license.activate!(hardware_id: "HW-X") # same seat, no new row
    assert_raises(License::CapacityExceeded) { license.activate!(hardware_id: "HW-Y") }
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

  test "deactivate! frees the seat" do
    license = products(:cozy).licenses.create!(status: "active", max_activations: 1)
    license.activate!(hardware_id: "HW-X")
    assert license.deactivate!(hardware_id: "HW-X")
    assert_nil license.deactivate!(hardware_id: "HW-X") # already released
    assert license.activate!(hardware_id: "HW-Y") # slot is free again
  end
end
