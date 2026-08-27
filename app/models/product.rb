require "ed25519"

class Product < ApplicationRecord
  Variant = Data.define(:price_id, :name, :amount_cents, :seats)
  UpgradeVariant = Data.define(:price_id, :name, :amount_cents, :currency, :seats, :from_seats)

  # Shared with License, which can override a product's policy per license.
  UPDATE_POLICIES = { lifetime: "lifetime", time_limited: "time_limited", versioned: "versioned" }.freeze

  # Branding lands in an inline style attribute and an <img src> on the customer-facing
  # portal, so both are validated here rather than trusted from the admin form.
  HEX_COLOR = /\A#(?:\h{3}|\h{6})\z/
  HTTP_URL = %r{\Ahttps?://\S+\z}

  # How each accent shade is mixed from the product's one accent color. 600 is the color
  # itself; the rest are tints toward white and shades toward black, matching the spacing of
  # Tailwind's own scales closely enough for badges, links and focus rings.
  # Every accent shade the stylesheet actually uses, and no more — each one costs a
  # color-mix() declaration on every branded page load.
  ACCENT_MIX = { 50 => [ 10, "white" ], 500 => [ 80, "white" ], 600 => nil,
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
  # Deterministic, unlike its four siblings: this one is a lookup key
  # (Api::BaseController finds the product by it) and carries a unique index, both of which
  # need the same plaintext to always produce the same ciphertext.
  encrypts :api_key, deterministic: true

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
    message: "must be a hex color, like #2563eb" }, allow_blank: true
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
                     price_id: nil, stripe_customer_id: nil, amount_cents: nil, currency: nil)
    # Ignore an unrecognized policy from price metadata (falls back to the product's) rather than
    # letting a bad enum string raise ArgumentError and wedge fulfillment on Stripe's retries.
    update_policy = update_policy.presence_in(UPDATE_POLICIES.values)
    effective = update_policy || self.update_policy
    license = licenses.create!(customer:, status: "active", max_activations: quantity,
      update_policy:, stripe_payment_id:, stripe_price_id: price_id, stripe_customer_id:,
      expires_at: license_expires_at(policy: effective),
      licensed_version: (current_version if effective == "versioned"))
    license.payments.create!(stripe_payment_intent: stripe_payment_id, kind: "purchase",
      amount_cents:, currency:) if stripe_payment_id
    license
  end

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
  # License#fallback_variant_price_id's cheapest-variant tiebreak. Upgrade prices (metadata
  # `upgrade_from_seats`) are excluded for the same reason: they're discounts against a license
  # the buyer already owns, not licenses for sale.
  def variants
    Rails.cache.fetch([ "product-variants", stripe_product_id, renewal_stripe_price_id ], expires_in: 5.minutes) do
      active_stripe_prices
        .reject { |p| p.id == renewal_stripe_price_id || p.metadata["upgrade_from_seats"].present? }
        .map do |p|
          Variant.new(price_id: p.id, name: p.nickname, amount_cents: p.unit_amount, seats: seats_for(p))
        end.sort_by(&:amount_cents)
    end
  end

  # Seat-upgrade SKUs: a price with metadata `upgrade_from_seats` moves an existing license
  # from that seat count to the price's own `seats`. Pay-the-difference is frozen into these
  # amounts per from→to pair, so checkout stays a plain fixed price (promo codes, MoR tax and
  # currency handling all unchanged).
  def upgrade_variants
    return [] if stripe_product_id.blank?
    Rails.cache.fetch([ "product-upgrade-variants", stripe_product_id ], expires_in: 5.minutes) do
      active_stripe_prices
        .select { |p| p.metadata["upgrade_from_seats"].present? }
        .map do |p|
          UpgradeVariant.new(price_id: p.id, name: p.nickname, amount_cents: p.unit_amount,
            currency: p.currency, seats: seats_for(p), from_seats: p.metadata["upgrade_from_seats"].to_i)
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

  # The one question every new sale carries. Seline only ever sees the browser side of a
  # purchase, and the channels that actually sell (a forum post, a newsletter, a friend)
  # arrive with no usable referrer at all, so asking the buyer beats tracking them. Stripe
  # stores the answer on the Session itself (custom_fields[0].dropdown.value) — nothing to
  # migrate, nothing to write on the webhook, and the weekly metrics script reads it out of
  # the sessions list it already pulls.
  #
  # Optional on purpose: a required question at the pay button is a conversion tax, and a
  # forced answer is a guess more often than it is data.
  #
  # `key` and every option `value` must be ALPHANUMERIC — Stripe rejects underscores and
  # hyphens, which is why it reads `indieappsales`. Changing a value silently breaks
  # comparison with earlier weeks, so add options, never rename them. The label is capped at
  # 50 characters and is the only copy available: managed payments forbids `custom_text`, so
  # there is no helper line under the field. Stripe does not translate custom labels either.
  #
  # ponytail: one constant shared by every product. Add a per-product column the day a
  # product needs its own question.
  SOURCE_FIELD = {
    key: "source", type: "dropdown", optional: true,
    label: { type: "custom", custom: "How did you find us?" },
    dropdown: { options: [
      { label: "Reddit",               value: "reddit" },
      { label: "Indie App Sales",      value: "indieappsales" },
      { label: "X/Twitter",            value: "xtwitter" },
      { label: "A newsletter or blog", value: "newsletterblog" },
      { label: "Search",               value: "search" },
      { label: "A friend",             value: "friend" },
      { label: "Somewhere else",       value: "other" } ] }
  }.freeze

  def create_checkout_session(price_id:, email:, renew_license_key: nil, upgrade_license_key: nil,
      client_reference_id: nil, affonso_referral: nil)
    # Fail loud rather than hand Stripe a nil redirect (e.g. a product created before
    # the checkout-URL columns existed and never re-saved).
    if checkout_success_url.blank? || checkout_cancel_url.blank?
      raise CheckoutNotConfigured, "#{slug} is missing its checkout success/cancel URL"
    end
    price = Stripe::Price.retrieve(price_id, stripe_opts)
    raise ActiveRecord::RecordNotFound unless price.product == stripe_product_id
    # The renewal price is a discount for people who already bought — /api/checkout takes any
    # price_id belonging to this product, so without this guard anyone could buy a brand-new
    # license at the renewal rate. Checking that the key is merely *present* did not achieve
    # that: any junk string got past it, then fulfill! failed to find the license and fell
    # through to issue_license!, minting a full new license at the discounted price. The key has
    # to resolve to a license of this product that is actually due for renewal.
    if renewal_stripe_price_id.present? && price.id == renewal_stripe_price_id &&
        !licenses.find_by(license_key: renew_license_key.to_s.strip)&.renewable?
      raise CheckoutNotConfigured, "#{slug} renewal price needs a renewable license key"
    end
    # Same reasoning for upgrade prices: they're pay-the-difference discounts, so the key has to
    # resolve to a license of this product actually sitting at the price's `upgrade_from_seats`.
    if price.metadata["upgrade_from_seats"].present? &&
        !licenses.find_by(license_key: upgrade_license_key.to_s.strip)&.upgradeable_with?(price)
      raise CheckoutNotConfigured, "#{slug} upgrade price needs an eligible license key"
    end
    # Never silently ship an unlimited-seat license from an unconfigured price: unlimited must be
    # declared (seats "unlimited"/"0"); anything else needs a seat count from price metadata or the
    # product default.
    if price.metadata["seats"].blank? && max_activations_default.blank?
      raise CheckoutNotConfigured, "#{slug} price #{price.id} has no seat count " \
        "(set price metadata `seats`, or the product's max_activations_default)"
    end
    # Ask only a first-time buyer. Decided by the PRICE, which is the one signal that is both
    # known this early and impossible to forge: the two guards above mean a renewal price
    # proves a renewable license and an upgrade price proves an eligible one, so neither is
    # reachable by anybody who does not already own this product.
    #
    # The license keys deliberately play no part. /api/checkout is public and copies both
    # straight off the URL, so a junk key, or a real key belonging to somebody else, would
    # silence the question on a genuine new sale — and comparing against `email` cannot fix
    # that, because the email is blank whenever the caller did not prefill one and Stripe has
    # not collected it yet. The price is known now and is already validated.
    owner_only_price = price.id == renewal_stripe_price_id ||
      price.metadata["upgrade_from_seats"].present?
    Stripe::Checkout::Session.create({
      mode: "payment", customer_creation: "always",
      managed_payments: { enabled: true }, # Stripe as merchant of record: calculates, collects &
      # remits global VAT/sales tax (no registrations on our end).
      # MoR owns tax config, so do NOT set automatic_tax here.
      allow_promotion_codes: true,          # show the coupon field at checkout
      # Only first-time buyers get asked. A renewal or a seat upgrade is an existing owner
      # who answered this once already, and asking again would double-count the channel
      # that actually brought them.
      custom_fields: owner_only_price ? [] : [ SOURCE_FIELD ],
      line_items: [ { price: price.id, quantity: 1 } ],
      customer_email: email.presence,
      client_reference_id: client_reference_id.presence, # optional caller-supplied analytics id, passed through to Stripe
      metadata: { licencio_product_id: id, price_id: price.id, quantity: seats_for(price),
                  update_policy: price.metadata["update_policy"].presence,
                  renew_license_key: renew_license_key.presence,
                  upgrade_license_key: upgrade_license_key.presence,
                  # The storefronts send Seline's visitor id as client_reference_id, but Seline
                  # matches a guest charge to a visit only by this metadata key. Same value,
                  # copied under the name Seline looks for.
                  seline_visitor_id: client_reference_id.presence,
                  # Affonso attributes commissions by reading exactly this key off the
                  # completed session; the storefront forwards its cookie as this param.
                  affonso_referral: affonso_referral.presence }.compact,
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

    def active_stripe_prices
      Stripe::Price.list({ product: stripe_product_id, active: true }, stripe_opts).data
    end

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
