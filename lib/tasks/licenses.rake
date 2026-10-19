namespace :licenses do
  # The old Lemon Squeezy import used 999 as an "unlimited seats" sentinel; nil is the real
  # representation now. Idempotent — safe to re-run. Run once on prod after the LS import.
  desc "Convert Lemon Squeezy 999-seat sentinels to nil (unlimited)"
  task normalize_unlimited: :environment do
    n = License.where(migration_source: "lemon_squeezy", max_activations: 999).update_all(max_activations: nil)
    puts "Converted #{n} license(s) to unlimited."
  end

  # Two halves of the same insurance policy. Run both today, not on the day you need them:
  # the signing key lives encrypted in this database, so neither works once it is gone.
  desc "Mint the offline rescue token that unlocks every install with no server: rake licenses:rescue_token[cozy]"
  task :rescue_token, [ :slug ] => :environment do |_, args|
    product = Product.find_by!(slug: args[:slug].presence || "cozy")
    warn "Rescue token for #{product.name}. Publishing it unlocks every install, forever."
    warn "Paste it into the app's license field, in place of a key.\n\n"
    puts product.rescue_token
  end

  desc "Print a product's Ed25519 signing key for cold storage: rake licenses:signing_key[cozy]"
  task :signing_key, [ :slug ] => :environment do |_, args|
    product = Product.find_by!(slug: args[:slug].presence || "cozy")
    warn "PRIVATE signing key for #{product.name}. Anyone holding it can mint licenses."
    warn "Put it in a password manager or on paper. Never in a repo, never in email.\n\n"
    puts product.eddsa_private_key
  end

  # Run once, after the band prices exist in Stripe and before the product's renewal column moves
  # to the band 1 renewal price. Dry run unless APPLY=1.
  desc "Give licenses sold under the old per-currency discount their band: rake licenses:backfill_regional_bands[cozy] APPLY=1"
  task :backfill_regional_bands, [ :slug ] => :environment do |_, args|
    product = Product.find_by!(slug: args[:slug].presence || "cozy")
    apply = ENV["APPLY"] == "1"
    counts = License.backfill_regional_bands!(product, dry_run: !apply)
    puts "#{apply ? "Backfilled" : "Dry run, would backfill"} #{product.slug}:"
    counts.sort.each { |band, n| puts "  #{band}: #{n}" }
    puts "Band 1 licenses keep regional_band nil and renew at the product's column." if counts.key?("band 1")
  end
end
