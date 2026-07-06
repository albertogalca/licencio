class Customer < ApplicationRecord
  has_many :licenses, dependent: :nullify
  has_many :activations, through: :licenses

  validates :email, presence: true, uniqueness: true
  validates :stripe_customer_id, uniqueness: true, allow_nil: true

  def self.upsert!(email:, name: nil, stripe_customer_id: nil)
    customer = find_or_initialize_by(email:)
    customer.name = name if name.present?
    customer.stripe_customer_id = stripe_customer_id if stripe_customer_id
    customer.save!
    customer
  end

  def self.authenticate_token(token)
    if token.present?
      where(auth_token_expires_at: Time.current..).find_by(auth_token: token)
    end
  end

  def deliver_magic_link_later(product:)
    regenerate_auth_token
    MagicLinkJob.perform_later(self, product)
  end

  def clear_auth_token!
    update!(auth_token: nil, auth_token_expires_at: nil)
  end

  private
    def regenerate_auth_token
      update!(auth_token: SecureRandom.urlsafe_base64(32), auth_token_expires_at: 30.minutes.from_now)
    end
end
