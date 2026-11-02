# Deal-site codes (AppSumo). Plaintext goes to stdout only, so redirect it straight to the file
# you upload; the database keeps a digest. Counts and notes go to stderr.
namespace :codes do
  desc "Generate codes and print them, one per line: bin/rails \"codes:generate[picmal,10000]\" > appsumo.csv"
  task :generate, [ :slug, :count, :source ] => :environment do |_, args|
    product = Product.find_by!(slug: args[:slug])
    count = Integer(args[:count].presence || 10_000, 10)
    codes = RedemptionCode.generate!(product:, count:, source: args[:source].presence || "appsumo")
    $stdout.puts codes
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
