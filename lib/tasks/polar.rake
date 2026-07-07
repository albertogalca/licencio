require "net/http"
require "json"

# One-off Polar → Licencio license import for Cozy. Preserves Polar-issued key strings.
#   POLAR_TOKEN=polar_oat_... DRY_RUN=1 bin/rails polar:import_cozy
# Drop DRY_RUN to actually import. Re-runnable: License::Importer skips keys already present.
namespace :polar do
  # license_keys benefit per Polar product. v1 buyers get licensed_version pinned; lifetime overrides.
  COZY_BENEFITS = {
    "0f965825-44c0-4cb1-9f52-baa0711f621a" => { update_policy: nil,        licensed_version: 1 }, # Cozy for Desktop
    "eadd5689-4d1f-4213-94d2-d0bf55f7a275" => { update_policy: "lifetime", licensed_version: nil } # Cozy (Lifetime)
  }.freeze
  STATUS_MAP = { "granted" => "active", "revoked" => "refunded", "disabled" => "inactive" }.freeze

  desc "Import Cozy license keys from Polar (preserving keys)"
  task import_cozy: :environment do
    token = ENV.fetch("POLAR_TOKEN")
    rows = COZY_BENEFITS.flat_map do |benefit_id, policy|
      each_license_key(token, benefit_id).map do |lk|
        { product_slug: "cozy", license_key: lk["key"],
          email: lk.dig("customer", "email"), name: lk.dig("customer", "name"),
          status: STATUS_MAP.fetch(lk["status"], "active"),
          max_activations: lk["limit_activations"], expires_at: lk["expires_at"],
          **policy }
      end
    end

    if ENV["DRY_RUN"]
      rows.each { |r| puts "#{r[:license_key]}  v#{r[:licensed_version] || '-'}/#{r[:update_policy] || 'versioned'}  #{r[:status]}  #{r[:email]}" }
      puts "#{rows.size} rows (dry run — nothing imported)"
    else
      puts License.import(rows, source: "polar").inspect
    end
  end
end

# Paginates GET /v1/license-keys/ for one benefit. Trailing slash required (307 otherwise).
def each_license_key(token, benefit_id)
  page = 1
  items = []
  loop do
    uri = URI("https://api.polar.sh/v1/license-keys/")
    uri.query = URI.encode_www_form(benefit_id:, page:, limit: 100)
    res = Net::HTTP.get_response(uri, "Authorization" => "Bearer #{token}")
    raise "Polar #{res.code}: #{res.body}" unless res.code == "200"
    body = JSON.parse(res.body)
    items.concat(body["items"])
    break if page >= body.dig("pagination", "max_page").to_i
    page += 1
  end
  items
end
