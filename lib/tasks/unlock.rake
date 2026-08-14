namespace :unlock do
  # Everyone who bought before the unlock flow existed still has to be able to unlock. This
  # reads the license table and writes the equivalent purchases, once. Idempotent — the
  # unique index on (provider, provider_order_id) makes a second run report "existing".
  #
  #   DRY_RUN=1 bin/rails "unlock:backfill_purchases[cozy]"   # count, write nothing
  #   bin/rails "unlock:backfill_purchases[cozy]"
  desc "Create purchases from existing licenses: unlock:backfill_purchases[cozy] (DRY_RUN=1 to preview)"
  task :backfill_purchases, [ :slug ] => :environment do |_, args|
    product = Product.find_by!(slug: args[:slug].presence || "cozy")
    dry_run = ENV["DRY_RUN"].present?

    counts = Purchase.backfill_from_licenses!(product, dry_run:)

    puts "#{dry_run ? "DRY RUN — " : ""}#{product.name}"
    puts "  created   #{counts[:created]}"
    puts "  existing  #{counts[:existing]}"
    # Trials, unclaimed imports, and licenses that say nothing about updates (no lifetime
    # policy, no expiry) — nothing to entitle, so nothing written.
    puts "  skipped   #{counts[:skipped]}"
    puts "  total     #{counts.values.sum}"
    puts "\nNothing was written. Re-run without DRY_RUN to apply." if dry_run
  end

  # An unlock token is verified offline, forever, by clients that may never contact this
  # server again. So there is exactly one way to rotate a signing key without stranding an
  # install: ship TWO public keys in every client from day one, and switch which one signs.
  # This mints the second ("b"), prints its private half ONCE, and stores only the public
  # half. Run it before the first client ships — afterwards it's too late to add.
  desc "Mint the backup Ed25519 signing key: unlock:generate_backup_key[cozy]"
  task :generate_backup_key, [ :slug ] => :environment do |_, args|
    product = Product.find_by!(slug: args[:slug].presence || "cozy")
    abort "#{product.name} already has a backup key (kid #{product.eddsa_backup_key_id})." if
      product.eddsa_backup_public_key.present?

    signing = Ed25519::SigningKey.generate
    private_key = Base64.strict_encode64(signing.to_bytes)
    public_key  = Base64.strict_encode64(signing.verify_key.to_bytes)

    product.update!(eddsa_backup_public_key: public_key, eddsa_backup_key_id: "b")

    warn "BACKUP PRIVATE KEY for #{product.name} — shown once, stored nowhere."
    warn "Put it in cold storage (password manager, paper, offline drive) NOW."
    warn "Anyone holding it can mint entitlement tokens that never expire.\n\n"
    puts private_key
    warn "\nEmbed BOTH public keys in every client, keyed by the token header's `kid`:\n\n"
    warn %(  "#{product.eddsa_key_id}": "#{product.eddsa_public_key}")
    warn %(  "b": "#{public_key}")
    warn "\nTo rotate later: set products.eddsa_key_id = \"b\" and re-import the private key."
  end
end
