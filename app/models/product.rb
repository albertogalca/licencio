require "ed25519"

class Product < ApplicationRecord
  Variant = Data.define(:price_id, :name, :amount_cents, :seats)

  # Shared with License, which can override a product's policy per license.
  UPDATE_POLICIES = { lifetime: "lifetime", time_limited: "time_limited", versioned: "versioned" }.freeze

  # Branding lands in an inline style attribute and an <img src> on the customer-facing
  # portal, so both are validated here rather than trusted from the admin form.
  HEX_COLOR = /\A#(?:\h{3}|\h{6})\z/
  HTTP_URL = %r{\Ahttps?://\S+\z}

  # How each accent shade is mixed from the product's one accent colour. 600 is the colour
  # itself; the rest are tints toward white and shades toward black, matching the spacing of
  # Tailwind's own scales closely enough for badges, links and focus rings.
  ACCENT_MIX = { 50 => [ 10, "white" ], 100 => [ 20, "white" ], 200 => [ 35, "white" ],
                 500 => [ 80, "white" ], 600 => nil,
                 700 => [ 82, "black" ], 800 => [ 68, "black" ] }.freeze

  has_many :licenses, dependent: :restrict_with_error
  has_many :activations, through: :licenses
  has_many :customers, through: :licenses
  has_many :purchases, dependent: :restrict_with_error
  has_many :login_codes, dependent: :delete_all

  encrypts :loops_api_key
  encrypts :eddsa_private_key
  encrypts :stripe_secret_key
  encrypts :stripe_webhook_secret

  enum :update_policy, UPDATE_POLICIES

  before_validation :generate_credentials, on: :create

  validates :name, :update_policy, presence: true
  validates :slug, :bundle_identifier, :license_prefix, :api_key,
    presence: true, uniqueness: true
  validates :eddsa_private_key, :eddsa_public_key, presence: true
  # time_limited licenses compute expires_at from update_duration_days; without it,
  # fulfillment hits nil.days and 500s. current_version pins versioned eligibility.
  validates :update_duration_days, presence: true, numericality: { greater_than: 0 },
    if: -> { update_policy == "time_limited" }
  validates :current_version, presence: true, if: -> { update_policy == "versioned" }
  validates :accent_color, :background_color, format: { with: HEX_COLOR,
    message: "must be a hex colour, like #2563eb" }, allow_blank: true
  validates :logo_url, format: { with: HTTP_URL,
    message: "must start with http:// or https://" }, allow_blank: true
  # A Stripe-selling product must carry its full credential set, so it can't validate yet
  # blow up at checkout/webhook. Blank secrets on edit are dropped by the controller, so an
  # already-configured product keeps its stored keys.
  with_options if: -> { stripe_product_id.present? } do
    validates :stripe_secret_key, :stripe_webhook_secret, :loops_transactional_id,
      :checkout_success_url, :checkout_cancel_url, presence: true
  end

  # Customers type whatever they remember on the recovery page — accept the slug or the
  # display name, any case.
  scope :matching, ->(value) {
    where("lower(slug) = :v OR lower(name) = :v", v: value.to_s.strip.downcase)
  }

  def loops_api_key_or_default
    loops_api_key.presence || ENV["LOOPS_API_KEY_DEFAULT"]
  end

  # Per-product theming for the customer-facing portal, emitted inline on <html> so it
  # overrides the defaults in application.css and leaves every unbranded page untouched.
  # Values are re-checked against the format here as well, because they're interpolated
  # straight into a style attribute — anything that doesn't match is dropped and that part
  # simply falls back to the default.
  def brand_style
    declarations = []

    if accent_color.to_s.match?(HEX_COLOR)
      declarations += ACCENT_MIX.map do |shade, mix|
        value = mix ? "color-mix(in oklab, #{accent_color} #{mix.first}%, #{mix.last})" : accent_color
        "--color-accent-#{shade}: #{value}"
      end
      # Primary buttons follow the accent too, reusing the shades just emitted above.
      declarations += [ "--brand-btn: var(--color-accent-600)",
                        "--brand-btn-hover: var(--color-accent-700)",
                        "--brand-btn-active: var(--color-accent-800)" ]
    end

    declarations << "--brand-bg: #{background_color}" if background_color.to_s.match?(HEX_COLOR)
    declarations.join("; ")
  end

  def verify_webhook(payload, signature)
    Stripe::Webhook.construct_event(payload, signature, stripe_webhook_secret)
  end

  def license_expires_at(from: Time.current, policy: update_policy)
    # ponytail: a time_limited license with no duration gets no expiry instead of crashing
    # (e.g. a per-license time_limited override on a product that never set update_duration_days).
    policy == "time_limited" && update_duration_days ? from + update_duration_days.days : nil
  end

  def issue_license!(customer:, quantity:, stripe_payment_id:, update_policy: nil,
                     price_id: nil, stripe_customer_id: nil, amount_cents: nil, currency: nil,
                     affiliate_id: nil, commission_cents: nil)
    # Ignore an unrecognized policy from price metadata (falls back to the product's) rather than
    # letting a bad enum string raise ArgumentError and wedge fulfillment on Stripe's retries.
    update_policy = update_policy.presence_in(UPDATE_POLICIES.values)
    effective = update_policy || self.update_policy
    license = licenses.create!(customer:, status: "active", max_activations: quantity,
      update_policy:, stripe_payment_id:, stripe_price_id: price_id, stripe_customer_id:,
      expires_at: license_expires_at(policy: effective),
      licensed_version: (current_version if effective == "versioned"))
    license.payments.create!(stripe_payment_intent: stripe_payment_id, kind: "purchase",
      amount_cents:, currency:, affiliate_id:, commission_cents:) if stripe_payment_id
    license
  end

  # A global affiliate isn't tied to any one product, but its magic-link email still ships through
  # some product's Loops config. The studio configures affiliate_transactional_id on one product;
  # that product is the sender. ponytail: first configured product; add a dedicated setting only if
  # a second sender is ever needed.
  def self.affiliate_mailer = where.not(affiliate_transactional_id: nil).order(:created_at).first

  # nil = unlimited seats — a deliberate SKU. A price declares it explicitly with seats
  # "unlimited"/"0"; create_checkout_session refuses a price that declares neither seat metadata
  # nor a product default, so nil here never leaks from a misconfiguration.
  def seats_for(price)
    raw = price.metadata["seats"].presence
    return if raw && raw.downcase.in?(%w[unlimited 0])
    seats = (raw || max_activations_default)&.to_i
    seats if seats&.positive?
  end

  # First line-item price of a completed Checkout Session (nil if none). A Stripe Payment
  # Link carries no session metadata, so fulfillment identifies and sizes the sale from the
  # purchased price (product ownership + `price.metadata["seats"]`). Uses stripe_opts, so
  # the product's stripe_secret_key must be set.
  def session_price(session)
    Stripe::Checkout::Session
      .list_line_items(session.id, { limit: 1 }, stripe_opts).data.first&.price
  end

  # What the storefront may sell. The renewal price is deliberately excluded: it's a discounted
  # "another year of updates" SKU that only means anything attached to an existing license, and
  # it's the cheapest price on the product — left in, it would headline the buy button and win
  # License#fallback_variant_price_id's cheapest-variant tiebreak.
  def variants
    Rails.cache.fetch([ "product-variants", stripe_product_id, renewal_stripe_price_id ], expires_in: 5.minutes) do
      Stripe::Price.list({ product: stripe_product_id, active: true }, stripe_opts).data
        .reject { |p| p.id == renewal_stripe_price_id }
        .map do |p|
          Variant.new(price_id: p.id, name: p.nickname, amount_cents: p.unit_amount, seats: seats_for(p))
        end.sort_by(&:amount_cents)
    end
  end

  # Distinct buyers of this product (Lemon Squeezy imports + Stripe), for the
  # storefront's "trusted by N" social proof.
  def customer_count = customers.distinct.count

  # Both halves or nothing: a code with no template can't be delivered, and a template
  # with no code would mail an empty discount.
  def student_discount? = student_transactional_id.present? && student_discount_code.present?

  CheckoutNotConfigured = Class.new(StandardError)

  def create_checkout_session(price_id:, email:, renew_license_key: nil, client_reference_id: nil, ref: nil)
    # Fail loud rather than hand Stripe a nil redirect (e.g. a product created before
    # the checkout-URL columns existed and never re-saved).
    if checkout_success_url.blank? || checkout_cancel_url.blank?
      raise CheckoutNotConfigured, "#{slug} is missing its checkout success/cancel URL"
    end
    price = Stripe::Price.retrieve(price_id, stripe_opts)
    raise ActiveRecord::RecordNotFound unless price.product == stripe_product_id
    # The renewal price is a discount for people who already bought — /api/checkout takes any
    # price_id belonging to this product, so without this guard anyone could buy a brand-new
    # license at the renewal rate.
    if renewal_stripe_price_id.present? && price.id == renewal_stripe_price_id && renew_license_key.blank?
      raise CheckoutNotConfigured, "#{slug} renewal price is not for sale on its own"
    end
    # Never silently ship an unlimited-seat license from an unconfigured price: unlimited must be
    # declared (seats "unlimited"/"0"); anything else needs a seat count from price metadata or the
    # product default.
    if price.metadata["seats"].blank? && max_activations_default.blank?
      raise CheckoutNotConfigured, "#{slug} price #{price.id} has no seat count " \
        "(set price metadata `seats`, or the product's max_activations_default)"
    end
    # An unknown or unapproved ref just drops out (nil) — checkout always proceeds.
    affiliate = Affiliate.approved.find_by(code: ref.to_s.downcase) if ref.present?
    Stripe::Checkout::Session.create({
      mode: "payment", customer_creation: "always",
      managed_payments: { enabled: true }, # Stripe as merchant of record: calculates, collects &
      # remits global VAT/sales tax (no registrations on our end).
      # MoR owns tax config, so do NOT set automatic_tax here.
      allow_promotion_codes: true,          # show the coupon field at checkout
      line_items: [ { price: price.id, quantity: 1 } ],
      customer_email: email.presence,
      client_reference_id: client_reference_id.presence, # optional caller-supplied analytics id, passed through to Stripe
      metadata: { licencio_product_id: id, price_id: price.id, quantity: seats_for(price),
                  update_policy: price.metadata["update_policy"].presence,
                  renew_license_key: renew_license_key.presence,
                  affiliate_id: affiliate&.id }.compact,
      success_url: checkout_success_url, cancel_url: checkout_cancel_url }, stripe_opts)
  end

  def trial_for(hardware_id:)
    return unless trial_days
    licenses.trials.joins(:activations).find_by(activations: { hardware_id: }) ||
      licenses.create!(status: "active", trial: true, max_activations: 1,
        expires_at: trial_days.days.from_now,
        licensed_version: (current_version if versioned?)).tap { |l| l.activate!(hardware_id:) }
  end

  # Offline license token: authenticity only. The server signs but never re-checks a token
  # (no verification endpoint), so it can't enforce the claims — the client is trusted to
  # honor `expires_at`/`update_eligible` and the `exp` lease. That `exp` (License::TOKEN_LEASE)
  # bounds offline validity: a refund takes effect when the client re-activates past the lease.
  #
  # `kid` names which public key signed, for clients that pin two of them (see
  # sign_unlock_token). Omitted when nil, so every existing caller's header is byte-identical
  # to what it was before rotation existed — an already-issued activation token still verifies.
  def sign_jwt(claims, kid: nil)
    key = Ed25519::SigningKey.new(Base64.strict_decode64(eddsa_private_key))
    header = { alg: "EdDSA", typ: "JWT", kid: }.compact
    input = [ header, claims ].map { |h| b64url(JSON.generate(h)) }.join(".")
    "#{input}.#{b64url(key.sign(input))}"
  end

  # The unlock entitlement: permanent, offline-verified, and never re-checked by this server.
  # Because clients honour it forever, the only workable rotation is two pinned public keys
  # (kid "a" and "b") shipped in every build; flipping eddsa_key_id changes which one signs
  # without stranding a single install. See rake unlock:generate_backup_key.
  def sign_unlock_token(claims) = sign_jwt(claims, kid: eddsa_key_id)

  # The promise that outlives this server: publish one of these and every install unlocks
  # itself, forever, with no network. '*' goes where a normal token binds one device and one
  # nonce, so the client's existing replay check becomes the marker check — a real activation
  # token can never be passed off as one of these, and one of these fits any machine.
  #
  # Mint it NOW and keep it offsite. eddsa_private_key is encrypted in this database, so a
  # database you can no longer reach is a promise you can no longer keep. Shutdown day is the
  # worst possible time to discover that.
  RESCUE_MARKER = "*"

  def rescue_token(years: 100)
    # Braced: sign_jwt now takes a kid: keyword, so a bare claims hash would be read as
    # keyword arguments instead of the claims.
    sign_jwt({ hardware_id: RESCUE_MARKER, license_key: "OFFLINE", expires_at: nil,
      update_eligible: true, nonce: RESCUE_MARKER,
      iat: Time.current.to_i, exp: years.years.from_now.to_i })
  end

  private
    def stripe_opts = { api_key: stripe_secret_key }

    def b64url(bytes) = Base64.urlsafe_encode64(bytes, padding: false)

    def generate_credentials
      self.api_key ||= "prod_#{SecureRandom.alphanumeric(32)}"
      generate_eddsa_keypair if eddsa_private_key.blank?
    end

    def generate_eddsa_keypair
      signing_key = Ed25519::SigningKey.generate
      self.eddsa_private_key = Base64.strict_encode64(signing_key.to_bytes)
      self.eddsa_public_key  = Base64.strict_encode64(signing_key.verify_key.to_bytes)
    end
end
