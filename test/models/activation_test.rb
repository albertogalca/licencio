require "test_helper"

class ActivationTest < ActiveSupport::TestCase
  test "fixtures are valid" do
    assert activations(:cozy_macbook).valid?
    assert activations(:cozy_deactivated).valid?
  end

  test "requires hardware_id, activated_at, and a license" do
    activation = Activation.new
    assert_not activation.valid?
    assert_includes activation.errors.attribute_names, :hardware_id
    assert_includes activation.errors.attribute_names, :activated_at
    assert_includes activation.errors.attribute_names, :license
  end

  test "belongs to license" do
    assert_equal licenses(:cozy_active), activations(:cozy_macbook).license
  end
end
