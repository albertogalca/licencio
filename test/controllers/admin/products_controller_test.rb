require "test_helper"

class Admin::ProductsControllerTest < ActionDispatch::IntegrationTest
  test "requires admin sign-in" do
    get admin_products_path
    assert_redirected_to new_admin_session_path
  end

  test "creating a product auto-generates credentials" do
    sign_in
    assert_difference -> { Product.count }, 1 do
      post admin_products_path, params: { product: {
        name: "Anodize", slug: "anodize", bundle_identifier: "com.cantimplora.anodize",
        license_prefix: "ANOD", update_policy: "lifetime", max_activations_default: 3 } }
    end
    product = Product.find_by!(slug: "anodize")
    assert_redirected_to edit_admin_product_path(product)
    assert product.api_key.present?
    assert product.eddsa_public_key.present?
  end

  private
    def sign_in
      post admin_session_path, params: { email: "admin@licencio.example", password: "secret123" }
    end
end
