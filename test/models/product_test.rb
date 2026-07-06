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

  test "a Stripe product id requires its secrets and a Loops template" do
    product = products(:cozy) # no stripe_product_id → creds optional
    assert product.valid?

    product.stripe_product_id = "prod_x"
    product.stripe_secret_key = product.stripe_webhook_secret = product.loops_transactional_id = nil
    assert_not product.valid?
    assert_includes product.errors.attribute_names, :stripe_secret_key
    assert_includes product.errors.attribute_names, :stripe_webhook_secret
    assert_includes product.errors.attribute_names, :loops_transactional_id

    product.stripe_secret_key = "sk_test"
    product.stripe_webhook_secret = "whsec_test"
    product.loops_transactional_id = "tmpl_test"
    assert product.valid?
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

  test "variants maps Stripe prices, sorts by amount, and reads seats from metadata" do
    list = Struct.new(:data).new([
      fake_price("price_c", "3 seats", 4077, { "seats" => "3" }),
      fake_price("price_a", "1 seat",  1599, { "seats" => "1" }),
      fake_price("price_b", "2 seats", 2878, { "seats" => "2" })
    ])
    Stripe::Price.stub(:list, list) do
      variants = products(:picmal).variants
      assert_equal %w[price_a price_b price_c], variants.map(&:price_id) # amount-sorted
      assert_equal [ 1, 2, 3 ], variants.map(&:seats)
      assert_equal "1 seat", variants.first.name
      assert_equal 1599, variants.first.amount_cents
    end
  end

  test "variants falls back to max_activations_default when seats metadata is absent" do
    list = Struct.new(:data).new([ fake_price("price_x", "Studio", 12000, {}) ])
    Stripe::Price.stub(:list, list) do
      assert_equal products(:picmal).max_activations_default, products(:picmal).variants.first.seats
    end
  end

  private
    def fake_price(id, nickname, unit_amount, metadata)
      Struct.new(:id, :nickname, :unit_amount, :metadata).new(id, nickname, unit_amount, metadata)
    end

    def create_product
      suffix = SecureRandom.hex(4)
      Product.create!(
        name: "New #{suffix}", slug: "new-#{suffix}",
        bundle_identifier: "com.x.new-#{suffix}",
        license_prefix: "NEW#{suffix}", update_policy: "lifetime"
      )
    end
end
