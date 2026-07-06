require "ed25519"

class Product < ApplicationRecord
  # A purchasable option = one Stripe Price on this product's Stripe Product.
  # nickname → label, unit_amount → price, metadata.seats → license max_activations.
  Variant = Data.define(:price_id, :name, :amount_cents, :seats)

  has_many :licenses, dependent: :restrict_with_error

  encrypts :loops_api_key
  encrypts :eddsa_private_key

  enum :update_policy, { lifetime: "lifetime", time_limited: "time_limited", versioned: "versioned" }

  before_validation :generate_credentials, on: :create

  validates :name, :update_policy, presence: true
  validates :slug, :bundle_identifier, :license_prefix, :api_key,
    presence: true, uniqueness: true
  validates :eddsa_private_key, :eddsa_public_key, presence: true
  validates :max_activations_default, presence: true

  def loops_api_key_or_default
    loops_api_key.presence || ENV["LOOPS_API_KEY_DEFAULT"]
  end

  def license_expires_at(from: Time.current)
    time_limited? ? from + update_duration_days.days : nil
  end

  def issue_license!(customer:, quantity:, stripe_payment_id:)
    licenses.create!(customer:, status: "active", max_activations: quantity,
      stripe_payment_id:, expires_at: license_expires_at,
      licensed_version: (current_version if versioned?))
  end

  def variants
    Stripe::Price.list(product: stripe_product_id, active: true).data.map do |p|
      Variant.new(price_id: p.id, name: p.nickname, amount_cents: p.unit_amount,
        seats: (p.metadata["seats"] || max_activations_default).to_i)
    end.sort_by(&:amount_cents)
  end

  def sign_jwt(claims)
    key = Ed25519::SigningKey.new(Base64.strict_decode64(eddsa_private_key))
    input = [ { alg: "EdDSA", typ: "JWT" }, claims ].map { |h| b64url(JSON.generate(h)) }.join(".")
    "#{input}.#{b64url(key.sign(input))}"
  end

  private
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
