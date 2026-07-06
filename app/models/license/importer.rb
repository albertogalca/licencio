class License::Importer
  def self.import(rows, source:) = new(source:).import(rows)

  def initialize(source:)
    @source = source
  end

  def import(rows)
    imported = skipped = 0
    errors = []
    rows.each_with_index do |row, i|
      row = row.to_h.with_indifferent_access
      if License.exists?(license_key: row[:license_key])
        skipped += 1
      else
        import_row(row)
        imported += 1
      end
    rescue => e
      errors << { row: i, error: e.message }
    end
    { imported:, skipped:, errors: }
  end

  private
    attr_reader :source

    def import_row(row)
      License.transaction do
        product  = Product.find_by!(slug: row[:product_slug])
        # Blank email → unclaimed license (schema allows a null customer); the buyer claims it later.
        customer = Customer.upsert!(email: row[:email], name: row[:name]) if row[:email].present?
        license  = product.licenses.create!(
          license_key: row[:license_key], customer:, migration_source: source,
          status: row[:status].presence || "active",
          max_activations: row[:max_activations].presence || product.max_activations_default,
          # Per-license policy override (blank → inherits product). Versioned buyers need
          # licensed_version set or update_eligible? is false; lifetime-variant buyers set update_policy.
          update_policy: row[:update_policy].presence, licensed_version: row[:licensed_version].presence,
          expires_at: row[:expires_at], claimed_at: row[:claimed_at])
        activation_rows(row).each do |a|
          license.activations.create!(
            hardware_id: a[:hardware_id], device_name: a[:device_name],
            activated_at: a[:activated_at].presence || Time.current,
            deactivated_at: a[:deactivated_at])
        end
        license
      end
    end

    def activation_rows(row)
      if row[:activations].present?
        Array(row[:activations]).map { |a| a.to_h.with_indifferent_access }
      elsif row[:hardware_id].present?  # flat CSV single-activation column
        [ row.slice(:hardware_id, :device_name, :activated_at, :deactivated_at) ]
      else
        []
      end
    end
end
