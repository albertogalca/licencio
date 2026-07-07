class Customer < ApplicationRecord
  has_many :licenses, dependent: :nullify
  has_many :activations, through: :licenses
  has_many :portal_tokens, dependent: :delete_all

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

  def send_portal_access_later(product:)
    return unless licenses.exists?(product:) # nothing to deliver — don't issue a token or email
    token = PortalToken.issue!(customer: self, product:)
    PortalAccessJob.perform_later(token)
  end
end
