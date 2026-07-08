class License < ApplicationRecord
  belongs_to :product
  belongs_to :customer, optional: true
  has_many :activations, dependent: :destroy
  has_many :payments, dependent: :destroy

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

  # How early the portal offers renewal. A freshly renewed license (far from expiry) hides the
  # renew form; an expired or soon-to-expire one shows it.
  # ponytail: constant window; make it per-product only if a product ever needs its own.
  RENEWAL_WINDOW = 30.days

  # Renew makes sense only for a time_limited license on a Stripe product that's expired or nearly so.
  def renewable?
    effective_update_policy == "time_limited" && product.stripe_product_id.present? &&
      status.in?(%w[active expired]) && expires_at.present? && expires_at < RENEWAL_WINDOW.from_now
  end

  before_validation :assign_license_key, on: :create

  validates :license_key, presence: true, uniqueness: true
  validates :status, presence: true
  validates :licensed_version, presence: true, if: -> { product && effective_update_policy == "versioned" }

  def self.fulfill_from_stripe_session(product, session)
    meta = session.metadata
    # The dynamic /api/checkout tags the session with licencio_product_id — honor it, and
    # never mint for a session explicitly tagged for a different product. A Stripe Payment
    # Link carries no such tag, so fall through and confirm the purchased price is one of this
    # product's Stripe prices instead (the webhook is already per-product and signature-verified,
    # so the price check is the belt to that signature's suspenders — and it's what lets a
    # Dashboard-created Payment Link with no metadata fulfill).
    tag = meta.licencio_product_id.presence
    return if tag && tag.to_s != product.id.to_s
    quantity = meta[:quantity].presence&.to_i
    price = product.session_price(session) unless tag && quantity
    return unless tag || price&.product == product.stripe_product_id

    if quantity.nil?
      # Payment Link: seats live on the price. Refuse rather than mint an unlimited-seat
      # license (nil max_activations) from a price that declares no seat count anywhere.
      raise Product::CheckoutNotConfigured, "session #{session.id} has no seat count" if
        price.nil? || (price.metadata["seats"].blank? && product.max_activations_default.blank?)
      quantity = product.seats_for(price)
    end

    customer = Customer.upsert!(email: session.customer_details.email)
    license = fulfill!(
      product:, customer:, quantity:,
      stripe_payment_id: session.payment_intent || session.id,
      price_id: meta[:price_id].presence || price&.id,
      stripe_customer_id: session.customer,
      amount_cents: session.amount_total,
      currency: session.currency,
      update_policy: meta[:update_policy].presence || (price.metadata["update_policy"] if price),
      renew_key: meta[:renew_license_key])
    # Purchase email only when a license was actually issued — fulfill! returns nil on Stripe's
    # duplicate deliveries. subscribe is an idempotent upsert, safe to always run.
    if license
      customer.send_purchase_email_later(license:, amount: session.amount_total, currency: session.currency)
    end
    customer.subscribe_to_loops_later(product:)
    license
  end

  # Look the license up through its payment history (not licenses.stripe_payment_id, which a
  # renewal overwrites) so refunding the ORIGINAL purchase after a renewal still finds it.
  # Scoped to the refunding product's own licenses. Idempotent: a Stripe redelivery of
  # charge.refunded on an already-refunded license is a no-op (no duplicate refund emails).
  def self.refund!(product:, stripe_payment_intent:)
    license = product.licenses.joins(:payments)
      .find_by(payments: { stripe_payment_intent: })
    return if license.nil? || license.refunded?
    license.update!(status: "refunded")
    license.customer&.unsubscribe_from_loops_later(product: license.product)
    license.customer&.send_refund_email_later(license:)
  end

  # time_limited licenses only (lifetime = nil expires_at, excluded). Reminds any active,
  # not-yet-reminded license expiring within `days` — so a missed daily run catches up next run
  # instead of dropping that cohort. reminded_at makes it one send per license per expiry;
  # renew! clears it so a renewed license is reminded again as its new expiry approaches.
  def self.remind_expiring!(days: 7)
    active.where(reminded_at: nil, expires_at: Time.current..days.days.from_now).find_each do |license|
      license.customer&.send_expiry_reminder_later(license:)
      license.update_column(:reminded_at, Time.current)
    end
  end

  def self.fulfill!(product:, customer:, quantity:, stripe_payment_id:, price_id: nil,
                    stripe_customer_id: nil, amount_cents: nil, currency: nil,
                    renew_key: nil, update_policy: nil)
    # Idempotency backbone: one Payment per Stripe intent. Catches redelivery of the original
    # purchase even after a renewal has overwritten the license's own stripe_payment_id.
    return if Payment.exists?(stripe_payment_intent: stripe_payment_id)
    transaction do
      existing = renew_key && product.licenses.find_by(license_key: renew_key)
      # Renew only a license the payer already owns, or an unclaimed (imported) one the payer now
      # claims — never let a client-supplied renew_key renew someone else's license.
      if existing && (existing.customer_id.nil? || existing.customer_id == customer&.id)
        existing.renew!(stripe_payment_id:, price_id:, buyer: customer)
      else
        product.issue_license!(customer:, quantity:, stripe_payment_id:, price_id:,
          stripe_customer_id:, amount_cents:, currency:, update_policy:)
      end
    end
  rescue ActiveRecord::RecordNotUnique
    nil
  end

  def renew!(stripe_payment_id:, price_id: nil, buyer: nil)
    with_lock do
      # Idempotent under Stripe's at-least-once retries: a duplicate delivery of the
      # same renewal carries the same payment id and must not extend the window twice.
      next self if self.stripe_payment_id == stripe_payment_id
      from = [ expires_at, Time.current ].compact.max
      update!(status: "active", stripe_payment_id:, reminded_at: nil,
        customer: customer || buyer,               # claim an unclaimed imported license on renewal
        stripe_price_id: price_id || stripe_price_id,
        expires_at: product.license_expires_at(from:, policy: effective_update_policy))
      payments.create!(stripe_payment_intent: stripe_payment_id, kind: "renewal")
      self
    end
  end

  def deliver_later
    customer&.send_portal_access_later(product:)
  end

  RESENDABLE_EMAILS = %w[portal purchase refund expiry].freeze

  # Which lifecycle emails make sense to (re)send for this license, given its state.
  def resendable_emails
    return [] unless customer
    kinds = [ "portal" ]                                   # access link: always available
    kinds << "purchase" if payments.kind_purchase.exists? # receipt: only if there was a payment
    kinds << "refund"   if refunded?
    kinds << "expiry"   if effective_update_policy == "time_limited" && expires_at
    kinds
  end

  # Admin resend: clear the one-shot dedup so the re-enqueued job actually sends again, then
  # re-trigger the original email from persisted records (purchase amount comes off the Payment,
  # not a live Stripe session). Portal keys on a fresh token id, so the clear no-ops there — it
  # re-sends regardless. Returns the enqueued job, or nil when nothing was sent.
  def redeliver_email_later(kind)
    return unless customer && resendable_emails.include?(kind)
    Notification.where(customer_id:, kind:, reference_id: id).delete_all
    case kind
    when "portal"   then customer.send_portal_access_later(product:)
    when "purchase"
      payment = payments.kind_purchase.order(:created_at).last
      customer.send_purchase_email_later(license: self, amount: payment&.amount_cents, currency: payment&.currency)
    when "refund"   then customer.send_refund_email_later(license: self)
    when "expiry"   then customer.send_expiry_reminder_later(license: self)
    end
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
    # time_limited: expires_at IS the update window (issued as from+duration, and renew! extends it),
    # so eligibility tracks it directly. A renewal restores updates; a duration-less override that
    # never set expires_at grants updates rather than crashing on nil.days.
    else                  expires_at ? expires_at.future? : true
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
