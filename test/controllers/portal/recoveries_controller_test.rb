require "test_helper"

class Portal::RecoveriesControllerTest < ActionDispatch::IntegrationTest
  test "an unbranded product renders the page with the default theme" do
    get new_portal_recovery_path(product: "cozy")
    assert_response :success
    assert_no_brand_style
    assert_select "img[alt=?]", "Cozy", count: 0
  end

  test "a branded product themes the page it is asked for" do
    products(:cozy).update!(accent_color: "#7c3aed", background_color: "#faf0e3",
      logo_url: "https://cozyjournal.app/logo.svg")

    get new_portal_recovery_path(product: "cozy")
    assert_response :success
    assert_includes brand_style_block, "--color-accent-600: #7c3aed"
    assert_includes brand_style_block, "--brand-bg: #faf0e3"
    assert_select "img[src=?][alt=?]", "https://cozyjournal.app/logo.svg", "Cozy"
  end

  # The form accepts the display name too, and redirects back with whatever was typed —
  # so the page it lands on has to brand off the same lookup create used.
  test "a branded product is found by display name as well as slug" do
    products(:cozy).update!(accent_color: "#7c3aed", logo_url: "https://cozyjournal.app/logo.svg")

    get new_portal_recovery_path(product: products(:cozy).name.upcase)
    assert_response :success
    assert_includes brand_style_block, "--color-accent-600: #7c3aed"
    assert_select "img[src=?]", "https://cozyjournal.app/logo.svg"
  end

  test "branding does not leak across products" do
    products(:cozy).update!(accent_color: "#7c3aed", logo_url: "https://cozyjournal.app/logo.svg")

    get new_portal_recovery_path(product: "picmal")
    assert_response :success
    assert_no_brand_style
    assert_select "img[src=?]", "https://cozyjournal.app/logo.svg", count: 0
  end

  private
    # Themed as a nonced <style> block, not a style attribute — see the portal layout. The
    # nonce has to be there or our style-src :self CSP drops the block silently.
    def brand_style_block
      tag = css_select("style").first
      assert_not_nil tag, "expected a brand <style> block"
      assert_predicate tag["nonce"].to_s, :present?, "brand <style> needs a CSP nonce"
      tag.text
    end

    def assert_no_brand_style
      assert_empty css_select("style"), "an unbranded page must not override anything"
    end
end
