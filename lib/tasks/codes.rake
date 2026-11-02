# Deal-site codes (AppSumo). Plaintext is written once, to OUT or stdout; the database keeps a
# digest. Prefer OUT: on a server, boot warnings also land on stdout and would end up in the file.
# Counts and notes go to stderr.
namespace :codes do
  desc "Generate codes, one per line: bin/rails \"codes:generate[picmal,10000]\" OUT=appsumo.csv"
  task :generate, [ :slug, :count, :source ] => :environment do |_, args|
    product = Product.find_by!(slug: args[:slug])
    count = Integer(args[:count].presence || "10000", 10)
    codes = RedemptionCode.generate!(product:, count:, source: args[:source].presence || "appsumo")
    if ENV["OUT"].present?
      File.write(ENV["OUT"], codes.join("\n") + "\n", perm: 0o600)
    else
      $stdout.puts codes
    end
    warn "Generated #{codes.size} codes for #{product.name}. This is the only time they are shown."
  end

  desc "Import a code list, one per line, no header: bin/rails \"codes:import[picmal,appsumo.csv]\""
  task :import, [ :slug, :path, :source ] => :environment do |_, args|
    product = Product.find_by!(slug: args[:slug])
    tally = File.open(args[:path]) do |io|
      RedemptionCode.import!(product:, io:, source: args[:source].presence || "appsumo")
    end
    warn "#{product.name}: #{tally[:imported]} imported, #{tally[:duplicates]} already in the pool, " \
      "#{tally[:invalid]} rejected (blank, or outside #{RedemptionCode::IMPORT_LENGTHS})."
  end
end
