class License < ApplicationRecord
  belongs_to :product
  belongs_to :customer, optional: true
  has_many :activations, dependent: :destroy

  # status writers: "active" (issue/renew/trial/import), "refunded" (refund!),
  # "expired" (hourly expire_overdue! sweep), "inactive" (polar import: disabled keys).
  enum :status, { active: "active", inactive: "inactive", expired: "expired", refunded: "refunded" }
  enum :migration_source, { lemon_squeezy: "lemon_squeezy", polar: "polar" }, prefix: true

  scope :search, ->(term) {
    pattern = "%#{term.to_s.strip}%"
    left_joins(:customer, :product).where(
      "licenses.license_key ILIKE :p OR licenses.status ILIKE :p OR " \
      "customers.email ILIKE :p OR customers.name ILIKE :p OR products.name ILIKE :p", p: pattern)
  }

  enum :update_policy, Product::UPDATE_POLICIES, prefix: :policy

  scope :trials, -> { where(trial: true) }

  CapacityExceeded = Class.new(StandardError)

  # Token lease: how long an issued token is trusted offline before the client must
  # re-activate. Bounds the offline revocation window (a refund only takes effect on the
  # next re-activation). ponytail: constant; add a per-product token_ttl_days column if a
  # product ever needs its own window.
  TOKEN_LEASE = 7.days

  before_validation :assign_license_key, on: :create

  validates :license_key, presence: true, uniqueness: true
  validates :status, presence: true
  validates :licensed_version, presence: true, if: -> { product && effective_update_policy == "versioned" }

  def self.fulfill_from_stripe_session(product, session)
    # The session must name the same product whose webhook secret signed it — a
    # signed event can't mint a license for a different product.
    return if session.metadata.licencio_product_id.to_s != product.id.to_s

    customer = Customer.upsert!(
      email: session.customer_details.email, stripe_customer_id: session.customer)
    license = fulfill!(
      product:, customer:,
      quantity: session.metadata[:quantity]&.to_i,
      stripe_payment_id: session.payment_intent || session.id,
      update_policy: session.metadata[:update_policy],
      renew_key: session.metadata[:renew_license_key])
    license&.deliver_later
    license
  end

  # Keyed on payment_intent, which card Checkout always populates. A session fulfilled
  # via the `session.id` fallback (async payment methods only — not used today) wouldn't
  # be matched here; revisit if async payment methods are enabled.
  def self.refund!(stripe_payment_id:)
    find_by(stripe_payment_id:)&.update!(status: "refunded")
  end

  def self.fulfill!(product:, customer:, quantity:, stripe_payment_id:, renew_key: nil, update_policy: nil)
    return if exists?(stripe_payment_id:)
    license = renew_key && product.licenses.find_by(license_key: renew_key, customer_id: customer&.id)
    if license
      license.renew!(stripe_payment_id:)
    else
      product.issue_license!(customer:, quantity:, stripe_payment_id:, update_policy:)
    end
  rescue ActiveRecord::RecordNotUnique
    nil
  end

  def renew!(stripe_payment_id:)
    with_lock do
      # Idempotent under Stripe's at-least-once retries: a duplicate delivery of the
      # same renewal carries the same payment id and must not extend the window twice.
      next self if self.stripe_payment_id == stripe_payment_id
      from = [ expires_at, Time.current ].compact.max
      update!(status: "active", stripe_payment_id:,
        expires_at: product.license_expires_at(from:, policy: effective_update_policy))
      self
    end
  end

  def deliver_later
    customer&.send_portal_access_later(product:)
  end

  def activate!(hardware_id:, device_name: nil)
    with_lock do
      activations.active.find_by(hardware_id:) ||
        begin
          if max_activations && activations.active.count >= max_activations
            # Migration: a real device reclaims a Lemon Squeezy placeholder seat; once the
            # placeholders are gone the cap bites. Never evicts a real (non-provisional) device.
            activations.active.provisional.order(:activated_at).first&.deactivate! or
              raise CapacityExceeded
          end
          activations.create!(hardware_id:, device_name:, activated_at: Time.current)
        end
    end
  end

  # Materializes one active Lemon Squeezy activation as a placeholder that occupies a seat until a
  # real device reclaims it (see activate!). Idempotent on hardware_id; caps at max_activations.
  def import_provisional_activation!(hardware_id:, device_name:, activated_at:)
    return if activations.exists?(hardware_id:)
    return if max_activations && activations.active.count >= max_activations
    activations.create!(hardware_id:, device_name:, activated_at:, provisional: true)
  end

  def deactivate!(hardware_id:)
    activations.active.find_by(hardware_id:)&.deactivate!
  end

  def token_claims(hardware_id:, nonce:)
    { hardware_id:, license_key:, expires_at: expires_at&.iso8601,
      update_eligible: update_eligible?, nonce:,
      iat: Time.current.to_i, exp: TOKEN_LEASE.from_now.to_i }
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

  # Hourly sweep (config/recurring.yml) so status matches reality — an expired
  # time_limited license stops reading as "active" in admin, dashboards, and the
  # activation gate below.
  def self.expire_overdue! = active.where("expires_at < ?", Time.current).update_all(status: "expired", updated_at: Time.current)

  def expired? = expires_at&.past? || false

  # The activation gate: active status AND not past its expiry. The sweep keeps
  # status honest, but check expires_at here too so a just-expired license can't
  # slip a signed JWT between sweeps.
  def activatable? = active? && !expired?

  private
    def assign_license_key
      self.license_key ||= self.class.generate_key(product) if product
    end
end
