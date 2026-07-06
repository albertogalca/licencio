class License < ApplicationRecord
  belongs_to :product
  belongs_to :customer, optional: true
  has_many :activations, dependent: :destroy

  enum :status, { active: "active", inactive: "inactive", expired: "expired", refunded: "refunded" }
  enum :migration_source, { lemon_squeezy: "lemon_squeezy", polar: "polar" }, prefix: true

  # Admin free-text search across the license and its customer/product.
  scope :search, ->(term) {
    pattern = "%#{term.to_s.strip}%"
    left_joins(:customer, :product).where(
      "licenses.license_key ILIKE :p OR licenses.status ILIKE :p OR " \
      "customers.email ILIKE :p OR customers.name ILIKE :p OR products.name ILIKE :p", p: pattern)
  }
  # Nullable per-license override of the product's update policy. Nil → inherit product.
  enum :update_policy, { lifetime: "lifetime", time_limited: "time_limited", versioned: "versioned" }, prefix: :policy

  CapacityExceeded = Class.new(StandardError)

  before_validation :assign_license_key, on: :create

  validates :license_key, presence: true, uniqueness: true
  validates :status, :max_activations, presence: true
  # A versioned license without a version snapshot is never update-eligible — reject the footgun.
  validates :licensed_version, presence: true, if: :policy_versioned?

  # Turns a verified Stripe checkout session into a license and emails it. Returns the license
  # (nil if the payment was already fulfilled).
  def self.fulfill_from_stripe_session(session)
    customer = Customer.upsert!(
      email: session.customer_details.email, stripe_customer_id: session.customer)
    license = fulfill!(
      product: Product.find(session.metadata.licencio_product_id), customer:,
      quantity: session.metadata.quantity.to_i,
      stripe_payment_id: session.payment_intent || session.id,
      renew_key: session.metadata[:renew_license_key])
    license&.deliver_later
    license
  end

  def self.refund!(stripe_payment_id:)
    find_by(stripe_payment_id:)&.update!(status: "refunded")
  end

  def self.fulfill!(product:, customer:, quantity:, stripe_payment_id:, renew_key: nil)
    return if exists?(stripe_payment_id:)
    # Only the paying customer may renew their own key; anyone else's key issues a fresh license.
    license = renew_key && product.licenses.find_by(license_key: renew_key, customer_id: customer&.id)
    if license
      license.renew!(stripe_payment_id:)
    else
      product.issue_license!(customer:, quantity:, stripe_payment_id:)
    end
  end

  def renew!(stripe_payment_id:)
    from = [ expires_at, Time.current ].compact.max
    update!(status: "active", stripe_payment_id:, expires_at: product.license_expires_at(from:))
    self
  end

  def deliver_later
    LicenseDeliveryJob.perform_later(self)
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

  def self.import(rows, source:) = Importer.import(rows, source:)

  private
    def assign_license_key
      self.license_key ||= self.class.generate_key(product) if product
    end
end
