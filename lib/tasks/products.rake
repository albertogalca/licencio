namespace :products do
  # The key a bundle store sends to POST /api/licenses/issue. Rotating it cuts the store off
  # until it has the new one, so send it over before (or right after) you run this.
  desc "Mint or rotate a product's license-issuing key: rake products:rotate_issuance_key[cozy]"
  task :rotate_issuance_key, [ :slug ] => :environment do |_, args|
    product = Product.find_by!(slug: args.fetch(:slug))
    warn "New ISSUANCE key for #{product.name}. The old one, if any, stopped working just now."
    warn "Anyone holding it can mint licenses. Send it to the bundle store only, never in a client.\n\n"
    puts product.rotate_issuance_api_key!
  end

  # The client key. Every shipped build carries it, so every build older than this rotation
  # loses activate, deactivate and recover the moment it runs. Rebuild and ship first.
  desc "Rotate a product's client API key (breaks older builds): rake products:rotate_api_key[cozy]"
  task :rotate_api_key, [ :slug ] => :environment do |_, args|
    product = Product.find_by!(slug: args.fetch(:slug))
    warn "New CLIENT api_key for #{product.name}. Builds with the old key can no longer activate.\n\n"
    puts product.rotate_api_key!
  end
end
