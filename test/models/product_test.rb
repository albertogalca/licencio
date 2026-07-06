require "test_helper"

class ProductTest < ActiveSupport::TestCase
  test "fixtures are valid" do
    assert products(:cozy).valid?
    assert products(:picmal).valid?
  end

  test "requires name, slug, and update_policy" do
    product = Product.new
    assert_not product.valid?
    assert_includes product.errors.attribute_names, :name
    assert_includes product.errors.attribute_names, :slug
    assert_includes product.errors.attribute_names, :update_policy
  end

  test "slug, bundle_identifier, license_prefix, and api_key are unique" do
    existing = products(:cozy)
    dup = existing.dup
    assert_not dup.valid?
    assert_includes dup.errors.attribute_names, :slug
    assert_includes dup.errors.attribute_names, :bundle_identifier
    assert_includes dup.errors.attribute_names, :license_prefix
    assert_includes dup.errors.attribute_names, :api_key
  end

  test "update_policy enum" do
    assert products(:cozy).lifetime?
    assert products(:picmal).time_limited?
  end

  test "encrypts loops_api_key and eddsa_private_key at rest" do
    product = products(:cozy)
    ciphertext = Product.connection.select_value(
      "select eddsa_private_key from products where id = '#{product.id}'"
    )
    assert_not_equal "cozy_private_key", ciphertext
    assert_equal "cozy_private_key", product.reload.eddsa_private_key
  end

  test "has many licenses" do
    assert_equal 2, products(:cozy).licenses.count
  end

  test "generates api_key and an Ed25519 keypair on create" do
    product = create_product
    assert product.api_key.present?
    assert product.eddsa_private_key.present?
    assert product.eddsa_public_key.present?
  end

  test "keys are unique across products" do
    a = create_product
    b = create_product
    assert_not_equal a.api_key, b.api_key
    assert_not_equal a.eddsa_private_key, b.eddsa_private_key
    assert_not_equal a.eddsa_public_key, b.eddsa_public_key
  end

  test "private key decrypts to a valid Ed25519 key that derives the public key" do
    product = create_product
    signing = Ed25519::SigningKey.new(Base64.strict_decode64(product.reload.eddsa_private_key))
    derived = Base64.strict_encode64(signing.verify_key.to_bytes)
    assert_equal product.eddsa_public_key, derived
  end

  private
    def create_product
      suffix = SecureRandom.hex(4)
      Product.create!(
        name: "New #{suffix}", slug: "new-#{suffix}",
        bundle_identifier: "com.x.new-#{suffix}",
        license_prefix: "NEW#{suffix}", update_policy: "lifetime"
      )
    end
end
