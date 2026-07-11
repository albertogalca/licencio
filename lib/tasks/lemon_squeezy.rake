require "net/http"
require "json"

# Verifies imported Lemon Squeezy seat caps against LS's own activation_limit, then
# backfills mismatches. The LS import fell back to the product default when a row
# omitted max_activations, so multi-device buyers may carry the wrong cap.
#   LS_TOKEN=… DRY_RUN=1 bin/rails lemon_squeezy:verify_seats   # report only
#   LS_TOKEN=…            bin/rails lemon_squeezy:verify_seats   # report + backfill mismatches
# LS_PRODUCT_ID=… scopes the LS pull to one product (also flags LS keys never imported).
namespace :lemon_squeezy do
  # LS license_key.status → Licencio status. LS only emits these four; unknown → active.
  LS_STATUS_MAP = { "active" => "active", "inactive" => "inactive",
                    "expired" => "expired", "disabled" => "refunded" }.freeze

  # API-driven Lemon Squeezy → Licencio license import (preserving LS key strings). Mirrors
  # polar:import_cozy. Re-runnable: License::Importer skips keys already present, so a re-run
  # imports only the license keys sold since the last run.
  #   LS_TOKEN=… LS_PRODUCT_ID=651693 PRODUCT_SLUG=picmal DRY_RUN=1 bin/rails lemon_squeezy:import
  # Drop DRY_RUN to import. LS_PRODUCT_ID scopes the pull; PRODUCT_SLUG picks the local product.
  desc "Import Lemon Squeezy license keys (preserving keys); imports only new ones"
  task import: :environment do
    token = ENV.fetch("LS_TOKEN")
    slug  = ENV.fetch("PRODUCT_SLUG", "picmal")

    rows = LemonSqueezyApi.each_license_key(token, ENV["LS_PRODUCT_ID"]).map do |k|
      limit = k["activation_limit"].to_i  # LS 0/nil = unlimited → nil (product default)
      { product_slug: slug, license_key: k["key"],
        email: k["user_email"], name: k["user_name"],
        status: LS_STATUS_MAP.fetch(k["status"], "active"),
        max_activations: (limit.positive? ? limit : nil),
        expires_at: k["expires_at"] }
    end

    if ENV["DRY_RUN"].present?
      have = License.where(license_key: rows.map { |r| r[:license_key] }).pluck(:license_key).to_set
      new_rows = rows.reject { |r| have.include?(r[:license_key]) }
      new_rows.each { |r| puts "  NEW  #{r[:license_key]}  #{r[:status]}  seats=#{r[:max_activations] || '∞'}  #{r[:email]}" }
      puts "#{rows.size} LS keys, #{new_rows.size} new (dry run — nothing imported)"
    else
      puts License.import(rows, source: "lemon_squeezy").inspect
    end
  end

  desc "Compare/backfill max_activations against Lemon Squeezy activation_limit"
  task verify_seats: :environment do
    token = ENV.fetch("LS_TOKEN")
    dry   = ENV["DRY_RUN"].present?

    # LS activation_limit 0/nil = unlimited; we store unlimited as nil.
    by_key = LemonSqueezyApi.each_license_key(token, ENV["LS_PRODUCT_ID"]).each_with_object({}) do |a, h|
      limit = a["activation_limit"].to_i
      h[a["key"]] = { expected: (limit.positive? ? limit : nil),
                      instances: a["instances_count"].to_i, email: a["user_email"] }
    end
    puts "Fetched #{by_key.size} license key(s) from Lemon Squeezy."

    mismatch = []; overcapacity = []; not_in_ls = []
    License.migration_source_lemon_squeezy.includes(:activations).find_each do |lic|
      ls = by_key[lic.license_key]
      next not_in_ls << lic unless ls
      mismatch << [ lic, ls ] if lic.max_activations != ls[:expected]
      if ls[:expected] && lic.activations.active.count > ls[:expected]
        overcapacity << [ lic, ls ]
      end
    end
    imported_keys = License.migration_source_lemon_squeezy.pluck(:license_key).to_set
    ls_not_imported = by_key.keys.reject { |k| imported_keys.include?(k) }

    LemonSqueezyApi.report("MISMATCH (cap ≠ LS activation_limit)", mismatch) do |lic, ls|
      "#{lic.license_key}  #{ls[:email]}  #{lic.max_activations.inspect} → #{ls[:expected].inspect}  (LS instances: #{ls[:instances]})"
    end
    LemonSqueezyApi.report("OVERCAPACITY (active devices > corrected cap)", overcapacity) do |lic, ls|
      "#{lic.license_key}  #{ls[:email]}  active #{lic.activations.active.count} > cap #{ls[:expected]}"
    end
    LemonSqueezyApi.report("NOT IN LS (local key absent from LS — review by hand)", not_in_ls) do |lic|
      "#{lic.license_key}  cap #{lic.max_activations.inspect}"
    end
    puts "\nLS keys not imported locally: #{ls_not_imported.size}" \
      "#{" (pass LS_PRODUCT_ID to make this meaningful)" if ENV["LS_PRODUCT_ID"].blank?}"

    if dry
      puts "\nDRY RUN — nothing changed. #{mismatch.size} license(s) would be backfilled."
    elsif mismatch.any?
      License.transaction { mismatch.each { |lic, ls| lic.update!(max_activations: ls[:expected]) } }
      puts "\nBackfilled #{mismatch.size} license(s). (overcapacity/not_in_ls left untouched.)"
    else
      puts "\nNo mismatches — nothing to backfill."
    end
  end

  # Imports each active LS activation instance as a *provisional* placeholder that occupies a seat
  # until the real device reclaims it (License#activate! evicts the oldest provisional first). Preserves
  # current seat occupancy across the parallel cutover so maxed-out buyers can't grab extra seats.
  # Idempotent (skips instances already imported) — safe to re-run near the end of the migration.
  #   LS_TOKEN=… DRY_RUN=1 bin/rails lemon_squeezy:import_instances   # report only
  #   LS_TOKEN=…            bin/rails lemon_squeezy:import_instances   # create placeholders
  # LS_PRODUCT_ID=… scopes the LS pull to one product (picmal).
  desc "Import active Lemon Squeezy instances as provisional seat placeholders"
  task import_instances: :environment do
    token = ENV.fetch("LS_TOKEN")
    dry   = ENV["DRY_RUN"].present?

    created = 0; no_license = 0; capped = []
    LemonSqueezyApi.each_license_key(token, ENV["LS_PRODUCT_ID"]).each do |a|
      license = License.migration_source_lemon_squeezy.find_by(license_key: a["key"])
      next(no_license += 1) unless license

      active = license.activations.active.count  # projected seat count (accurate in dry runs too)
      cap = license.max_activations
      LemonSqueezyApi.each_instance(token, a["id"]).each do |inst|
        hardware_id = "ls-#{inst['id']}"
        next if license.activations.exists?(hardware_id:)  # already imported — don't resurrect
        if cap && active >= cap
          capped << "#{license.license_key}  #{inst['name']}"
          next
        end
        active += 1
        created += 1
        license.import_provisional_activation!(
          hardware_id:, device_name: inst["name"], activated_at: inst["created_at"]) unless dry
      end
    end

    LemonSqueezyApi.report("CAPPED (LS instance over cap — not imported)", capped) { |r| r }
    puts "\n#{dry ? 'DRY RUN — would create' : 'Created'} #{created} provisional activation(s). " \
      "LS keys not imported locally: #{no_license}."
  end
end

# Namespaced so these helpers stay off top-level Object.
module LemonSqueezyApi
  module_function

  def report(title, rows)
    puts "\n== #{title}: #{rows.size} =="
    rows.each { |r| puts "  #{yield(*r)}" }
  end

  # License keys (attributes + JSON:API id), optionally scoped to one product.
  def each_license_key(token, product_id = nil)
    paginate(token, "license-keys", { "filter[product_id]" => product_id }.compact)
  end

  # Activation instances for one license key — each carries name + created_at + id.
  def each_instance(token, license_key_id)
    paginate(token, "license-key-instances", { "filter[license_key_id]" => license_key_id })
  end

  # Paginates a JSON:API collection, returning each item's attributes merged with its id.
  def paginate(token, resource, query = {})
    page = 1
    items = []
    loop do
      uri = URI("https://api.lemonsqueezy.com/v1/#{resource}")
      uri.query = URI.encode_www_form(query.merge("page[number]" => page, "page[size]" => 100))
      res = Net::HTTP.get_response(uri,
        "Authorization" => "Bearer #{token}", "Accept" => "application/vnd.api+json")
      raise "Lemon Squeezy #{res.code}: #{res.body}" unless res.code == "200"
      body = JSON.parse(res.body)
      items.concat(body["data"].map { |d| d["attributes"].merge("id" => d["id"]) })
      break if page >= body.dig("meta", "page", "lastPage").to_i
      page += 1
    end
    items
  end
end
