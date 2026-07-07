require "ed25519"

class Product < ApplicationRecord
  Variant = Data.define(:price_id, :name, :amount_cents, :seats)

  # Shared with License, which can override a product's policy per license.
  UPDATE_POLICIES = { lifetime: "lifetime", time_limited: "time_limited", versioned: "versioned" }.freeze

  has_many :licenses, dependent: :restrict_with_error
  has_many :activations, through: :licenses

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
  # A Stripe-selling product must carry its full credential set, so it can't validate yet
  # blow up at checkout/webhook. Blank secrets on edit are dropped by the controller, so an
  # already-configured product keeps its stored keys.
  with_options if: -> { stripe_product_id.present? } do
    validates :stripe_secret_key, :stripe_webhook_secret, :loops_transactional_id,
      :checkout_success_url, :checkout_cancel_url, presence: true
  end

  def loops_api_key_or_default
    loops_api_key.presence || ENV["LOOPS_API_KEY_DEFAULT"]
  end

  def verify_webhook(payload, signature)
    Stripe::Webhook.construct_event(payload, signature, stripe_webhook_secret)
  end

  def license_expires_at(from: Time.current, policy: update_policy)
    # ponytail: a time_limited license with no duration gets no expiry instead of crashing
    # (e.g. a per-license time_limited override on a product that never set update_duration_days).
    policy == "time_limited" && update_duration_days ? from + update_duration_days.days : nil
  end

  def issue_license!(customer:, quantity:, stripe_payment_id:, update_policy: nil)
    effective = update_policy || self.update_policy
    licenses.create!(customer:, status: "active", max_activations: quantity, update_policy:,
      stripe_payment_id:, expires_at: license_expires_at(policy: effective),
      licensed_version: (current_version if effective == "versioned"))
  end

  def seats_for(price)
    seats = (price.metadata["seats"].presence || max_activations_default)&.to_i
    seats if seats&.positive?
  end

  def variants
    Rails.cache.fetch([ "product-variants", stripe_product_id ], expires_in: 5.minutes) do
      Stripe::Price.list({ product: stripe_product_id, active: true }, stripe_opts).data.map do |p|
        Variant.new(price_id: p.id, name: p.nickname, amount_cents: p.unit_amount, seats: seats_for(p))
      end.sort_by(&:amount_cents)
    end
  end

  CheckoutNotConfigured = Class.new(StandardError)

  def create_checkout_session(price_id:, email:, renew_license_key: nil)
    # Fail loud rather than hand Stripe a nil redirect (e.g. a product created before
    # the checkout-URL columns existed and never re-saved).
    if checkout_success_url.blank? || checkout_cancel_url.blank?
      raise CheckoutNotConfigured, "#{slug} is missing its checkout success/cancel URL"
    end
    price = Stripe::Price.retrieve(price_id, stripe_opts)
    raise ActiveRecord::RecordNotFound unless price.product == stripe_product_id
    Stripe::Checkout::Session.create({
      mode: "payment", customer_creation: "always",
      line_items: [ { price: price.id, quantity: 1 } ],
      customer_email: email.presence,
      metadata: { licencio_product_id: id, quantity: seats_for(price),
                  update_policy: price.metadata["update_policy"].presence,
                  renew_license_key: renew_license_key.presence }.compact,
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
  def sign_jwt(claims)
    key = Ed25519::SigningKey.new(Base64.strict_decode64(eddsa_private_key))
    input = [ { alg: "EdDSA", typ: "JWT" }, claims ].map { |h| b64url(JSON.generate(h)) }.join(".")
    "#{input}.#{b64url(key.sign(input))}"
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
