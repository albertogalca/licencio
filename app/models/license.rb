class License < ApplicationRecord
  belongs_to :product
  belongs_to :customer, optional: true
  has_many :activations, dependent: :destroy

  enum :status, { active: "active", inactive: "inactive", expired: "expired", refunded: "refunded" }
  enum :migration_source, { lemon_squeezy: "lemon_squeezy", polar: "polar" }, prefix: true
  # Nullable per-license override of the product's update policy. Nil → inherit product.
  enum :update_policy, { lifetime: "lifetime", time_limited: "time_limited", versioned: "versioned" }, prefix: :policy

  CapacityExceeded = Class.new(StandardError)

  before_validation :assign_license_key, on: :create

  validates :license_key, presence: true, uniqueness: true
  validates :status, :max_activations, presence: true

  def self.fulfill!(product:, customer:, quantity:, stripe_payment_id:, renew_key: nil)
    return if exists?(stripe_payment_id:)
    if renew_key && (license = product.licenses.find_by(license_key: renew_key))
      license.renew!(stripe_payment_id:)
    else
      product.issue_license!(customer:, quantity:, stripe_payment_id:)
    end
  end

  def renew!(stripe_payment_id:)
    from = [ expires_at, Time.current ].compact.max
    update!(status: "active", stripe_payment_id:, expires_at: product.license_expires_at(from:))
  end

  def activate!(hardware_id:, device_name: nil)
    with_lock do
      activations.active.find_by(hardware_id:) ||
        begin
          raise CapacityExceeded if activations.active.count >= max_activations
          activations.create!(hardware_id:, device_name:, activated_at: Time.current)
        end
    end
  end

  def deactivate!(hardware_id:)
    activations.active.find_by(hardware_id:)&.update!(deactivated_at: Time.current)
  end

  def token_claims(hardware_id:, nonce:)
    { hardware_id:, license_key:, expires_at: expires_at&.iso8601,
      update_eligible: update_eligible?, nonce:, iat: Time.current.to_i }
  end

  def effective_update_policy
    update_policy || product.update_policy
  end

  def update_eligible?
    case effective_update_policy
    when "lifetime"  then true
    when "versioned" then licensed_version.present? && product.current_version <= licensed_version
    else                  (claimed_at || created_at) + product.update_duration_days.days > Time.current
    end
  end

  def self.generate_key(product)
    "#{product.license_prefix.downcase}_#{SecureRandom.alphanumeric(24).downcase}"
  end

  def self.find_by_key(key) = find_by(license_key: key)

  def self.import(rows, source:)
    imported = skipped = 0
    errors = []
    rows.each_with_index do |row, i|
      row = row.to_h.with_indifferent_access
      if exists?(license_key: row[:license_key])
        skipped += 1
      else
        import_row(row, source:)
        imported += 1
      end
    rescue => e
      errors << { row: i, error: e.message }
    end
    { imported:, skipped:, errors: }
  end

  def self.import_row(row, source:)
    transaction do
      product  = Product.find_by!(slug: row[:product_slug])
      customer = Customer.upsert!(email: row[:email], name: row[:name])
      license  = product.licenses.create!(
        license_key: row[:license_key], customer:, migration_source: source,
        status: row[:status].presence || "active",
        max_activations: row[:max_activations].presence || product.max_activations_default,
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

  def self.activation_rows(row)
    if row[:activations].present?
      Array(row[:activations]).map { |a| a.to_h.with_indifferent_access }
    elsif row[:hardware_id].present?  # flat CSV single-activation column
      [ row.slice(:hardware_id, :device_name, :activated_at, :deactivated_at) ]
    else
      []
    end
  end

  private
    def assign_license_key
      self.license_key ||= self.class.generate_key(product) if product
    end
end
