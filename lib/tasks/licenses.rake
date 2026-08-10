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
end
