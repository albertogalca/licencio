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
      PolarApi.each_license_key(token, benefit_id).map do |lk|
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

  # Imports active Polar activations as provisional seat placeholders (mirrors
  # lemon_squeezy:import_instances). Only capped licenses matter — an unlimited-seat license has no
  # seat to protect, and its placeholders would never be reclaimed, so those are skipped. A real
  # device later reclaims a placeholder via License#activate!. Idempotent; safe to re-run.
  #   POLAR_TOKEN=polar_oat_... DRY_RUN=1 bin/rails polar:import_instances   # report only
  #   POLAR_TOKEN=polar_oat_...            bin/rails polar:import_instances   # create placeholders
  desc "Import active Polar activations as provisional seat placeholders (capped licenses only)"
  task import_instances: :environment do
    token = ENV.fetch("POLAR_TOKEN")
    dry   = ENV["DRY_RUN"].present?

    created = 0; no_license = 0; unlimited = 0; capped = []
    COZY_BENEFITS.each_key do |benefit_id|
      PolarApi.each_license_key(token, benefit_id).each do |lk|
        license = License.migration_source_polar.find_by(license_key: lk["key"])
        next(no_license += 1) unless license
        next(unlimited += 1) if license.max_activations.nil?  # unlimited seats — nothing to preserve
        next if lk["usage"].to_i.zero?                        # no activations — skip the per-key GET

        active = license.activations.active.count  # projected seat count (accurate in dry runs too)
        cap = license.max_activations
        PolarApi.activations(token, lk["id"]).each do |act|
          hardware_id = "polar-#{act['id']}"
          next if license.activations.exists?(hardware_id:)  # already imported — don't resurrect
          if active >= cap
            capped << "#{license.license_key}  #{act['label']}"
            next
          end
          active += 1
          created += 1
          license.import_provisional_activation!(
            hardware_id:, device_name: act["label"], activated_at: act["created_at"]) unless dry
        end
      end
    end

    unless capped.empty?
      puts "\n== CAPPED (Polar activation over cap — not imported): #{capped.size} =="
      capped.each { |r| puts "  #{r}" }
    end
    puts "\n#{dry ? 'DRY RUN — would create' : 'Created'} #{created} provisional activation(s). " \
      "Unlimited-seat licenses skipped: #{unlimited}. Polar keys not imported locally: #{no_license}."
  end
end

# Namespaced so the pagination helper stays off top-level Object.
module PolarApi
  module_function

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

  # GET /v1/license-keys/{id} — returns the key with its activations array (id, label, created_at).
  def activations(token, license_key_id)
    res = Net::HTTP.get_response(
      URI("https://api.polar.sh/v1/license-keys/#{license_key_id}"), "Authorization" => "Bearer #{token}")
    raise "Polar #{res.code}: #{res.body}" unless res.code == "200"
    JSON.parse(res.body)["activations"] || []
  end
end
