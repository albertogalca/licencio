require "test_helper"

class Api::Admin::MigrationsControllerTest < ActionDispatch::IntegrationTest
  # Fixture products carry fake Ed25519 keys, so build a real one for the activate flow.
  setup do
    @product = Product.create!(
      name: "Testy", slug: "testy", bundle_identifier: "com.test.app",
      license_prefix: "TEST", update_policy: "lifetime", max_activations_default: 3)
    ENV["ADMIN_API_KEY"] = "admin-secret"
    @headers = { "Authorization" => "Bearer admin-secret" }
  end

  def import(licenses:, source: "polar", headers: @headers)
    post "/api/admin/migrations/import?source=#{source}",
      params: { licenses: }, headers:, as: :json
  end

  test "preserves the exact original key" do
    import(licenses: [ row(license_key: "polar_ABC123xyz") ])
    assert_response :ok
    assert_equal 1, response.parsed_body["imported"]
    assert License.find_by(license_key: "polar_ABC123xyz")
  end

  test "marks the correct migration_source" do
    import(licenses: [ row(license_key: "polar_1") ], source: "polar")
    assert License.find_by_key("polar_1").migration_source_polar?

    import(licenses: [ row(license_key: "ls_1") ], source: "lemon_squeezy")
    assert License.find_by_key("ls_1").migration_source_lemon_squeezy?
  end

  test "preserves historical activations including deactivated ones" do
    active_at = "2025-01-01T00:00:00Z"
    dead_on   = "2025-03-01T00:00:00Z"
    import(licenses: [ row(license_key: "polar_hist", activations: [
      { hardware_id: "HW-1", device_name: "Mac", activated_at: active_at },
      { hardware_id: "HW-2", activated_at: active_at, deactivated_at: dead_on }
    ]) ])
    assert_response :ok

    license = License.find_by_key("polar_hist")
    assert_equal 2, license.activations.count
    assert_equal 1, license.activations.active.count

    live = license.activations.find_by(hardware_id: "HW-1")
    assert_equal Time.parse(active_at), live.activated_at
    assert_equal "Mac", live.device_name

    dead = license.activations.find_by(hardware_id: "HW-2")
    assert_equal Time.parse(dead_on), dead.deactivated_at
  end

  test "an imported license validates via the activate API" do
    import(licenses: [ row(license_key: "polar_activate") ])
    assert_response :ok

    post "/api/licenses/activate",
      params: { license_key: "polar_activate", hardware_id: "HW-NEW", nonce: "n1" },
      headers: { "X-Api-Key" => @product.api_key }, as: :json
    assert_response :ok
    assert response.parsed_body["jwt"].present?
  end

  test "re-importing the same key is idempotent" do
    import(licenses: [ row(license_key: "polar_dup") ])
    assert_no_difference "License.count" do
      import(licenses: [ row(license_key: "polar_dup") ])
    end
    assert_equal 1, response.parsed_body["skipped"]
  end

  test "a bad row is collected without poisoning the batch" do
    import(licenses: [
      row(license_key: "polar_ok"),
      row(license_key: "polar_bad", product_slug: "does-not-exist")
    ])
    assert_response :ok
    body = response.parsed_body
    assert_equal 1, body["imported"]
    assert_equal 1, body["errors"].size
    assert License.find_by_key("polar_ok")
    assert_nil License.find_by_key("polar_bad")
  end

  test "missing or wrong bearer token is unauthorized" do
    import(licenses: [ row(license_key: "x") ], headers: {})
    assert_response :unauthorized

    import(licenses: [ row(license_key: "x") ], headers: { "Authorization" => "Bearer nope" })
    assert_response :unauthorized
  end

  test "unknown source is unprocessable" do
    import(licenses: [ row(license_key: "x") ], source: "paddle")
    assert_response :unprocessable_entity
  end

  private
    def row(license_key:, product_slug: "testy", **overrides)
      { license_key:, product_slug:, email: "legacy@example.com", name: "Legacy" }.merge(overrides)
    end
end
