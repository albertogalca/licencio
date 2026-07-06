require "test_helper"

class LicenseTest < ActiveSupport::TestCase
  test "fixtures are valid" do
    assert licenses(:cozy_active).valid?
    assert licenses(:cozy_unclaimed).valid?
    assert licenses(:picmal_expired).valid?
  end

  test "requires license_key, status, and max_activations" do
    license = License.new
    assert_not license.valid?
    assert_includes license.errors.attribute_names, :license_key
    assert_includes license.errors.attribute_names, :status
    assert_includes license.errors.attribute_names, :max_activations
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

  test "activate! is idempotent and enforces capacity" do
    license = products(:cozy).licenses.create!(status: "active", max_activations: 1)
    a = license.activate!(hardware_id: "HW-X")
    assert_equal a, license.activate!(hardware_id: "HW-X") # same seat, no new row
    assert_raises(License::CapacityExceeded) { license.activate!(hardware_id: "HW-Y") }
  end

  test "deactivate! frees the seat" do
    license = products(:cozy).licenses.create!(status: "active", max_activations: 1)
    license.activate!(hardware_id: "HW-X")
    assert license.deactivate!(hardware_id: "HW-X")
    assert_nil license.deactivate!(hardware_id: "HW-X") # already released
    assert license.activate!(hardware_id: "HW-Y") # slot is free again
  end
end
