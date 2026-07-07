require "net/http"
require "json"

# Verifies imported Lemon Squeezy seat caps against LS's own activation_limit, then
# backfills mismatches. The LS import fell back to the product default when a row
# omitted max_activations, so multi-device buyers may carry the wrong cap.
#   LS_TOKEN=… DRY_RUN=1 bin/rails lemon_squeezy:verify_seats   # report only
#   LS_TOKEN=…            bin/rails lemon_squeezy:verify_seats   # report + backfill mismatches
# LS_PRODUCT_ID=… scopes the LS pull to one product (also flags LS keys never imported).
namespace :lemon_squeezy do
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
end

# Namespaced so these helpers stay off top-level Object.
module LemonSqueezyApi
  module_function

  def report(title, rows)
    puts "\n== #{title}: #{rows.size} =="
    rows.each { |r| puts "  #{yield(*r)}" }
  end

  # Paginates GET /v1/license-keys (JSON:API), yielding each key's attributes hash.
  def each_license_key(token, product_id = nil)
    page = 1
    items = []
    loop do
      uri = URI("https://api.lemonsqueezy.com/v1/license-keys")
      query = { "page[number]" => page, "page[size]" => 100 }
      query["filter[product_id]"] = product_id if product_id.present?
      uri.query = URI.encode_www_form(query)
      res = Net::HTTP.get_response(uri,
        "Authorization" => "Bearer #{token}", "Accept" => "application/vnd.api+json")
      raise "Lemon Squeezy #{res.code}: #{res.body}" unless res.code == "200"
      body = JSON.parse(res.body)
      items.concat(body["data"].map { |d| d["attributes"] })
      break if page >= body.dig("meta", "page", "lastPage").to_i
      page += 1
    end
    items
  end
end
