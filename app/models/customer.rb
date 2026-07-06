class Customer < ApplicationRecord
  has_many :licenses, dependent: :nullify
  has_many :activations, through: :licenses

  validates :email, presence: true, uniqueness: true
  validates :stripe_customer_id, uniqueness: true, allow_nil: true

  scope :search, ->(term) {
    pattern = "%#{term.to_s.strip}%"
    where("customers.email ILIKE :p OR customers.name ILIKE :p", p: pattern)
  }
  scope :for_product, ->(product_id) {
    where(id: License.where(product_id: product_id).select(:customer_id))
  }

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

  def send_portal_access_later(product:)
    regenerate_auth_token
    PortalAccessJob.perform_later(self, product)
  end

  def clear_auth_token!
    update!(auth_token: nil, auth_token_expires_at: nil)
  end

  private
    def regenerate_auth_token
      update!(auth_token: SecureRandom.urlsafe_base64(32), auth_token_expires_at: 30.minutes.from_now)
    end
end
