namespace :licenses do
  # The old Lemon Squeezy import used 999 as an "unlimited seats" sentinel; nil is the real
  # representation now. Idempotent — safe to re-run. Run once on prod after the LS import.
  desc "Convert Lemon Squeezy 999-seat sentinels to nil (unlimited)"
  task normalize_unlimited: :environment do
    n = License.where(migration_source: "lemon_squeezy", max_activations: 999).update_all(max_activations: nil)
    puts "Converted #{n} license(s) to unlimited."
  end
end
