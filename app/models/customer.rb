class Customer < ApplicationRecord
  has_many :licenses, dependent: :nullify
  has_many :activations, through: :licenses
  has_many :portal_tokens, dependent: :delete_all

  validates :email, presence: true, uniqueness: true

  scope :search, ->(term) {
    pattern = "%#{term.to_s.strip}%"
    where("customers.email ILIKE :p OR customers.name ILIKE :p", p: pattern)
  }
  scope :for_product, ->(product_id) {
    where(id: License.where(product_id: product_id).select(:customer_id))
  }

  def self.upsert!(email:, name: nil)
    customer = find_or_initialize_by(email:)
    customer.name = name if name.present?
    customer.save!
    customer
  rescue ActiveRecord::RecordNotUnique
    # Concurrent first-time webhooks for the same email raced on the unique index — the other
    # won; reuse it (name reconciliation isn't worth a second write).
    find_by!(email:)
  end

  def send_portal_access_later(product:)
    return unless licenses.exists?(product:) # nothing to deliver — don't issue a token or email
    token = PortalToken.issue!(customer: self, product:)
    PortalAccessJob.perform_later(token)
  end

  def send_purchase_email_later(license:, amount:, currency:)
    token = PortalToken.issue!(customer: self, product: license.product)
    # Only the purchased/renewed key — not every key the customer owns (a receipt for one order).
    LicenseEmailJob.perform_later(token, template: :purchase_transactional_id,
      kind: "purchase", reference_id: license.id,
      data: { amount: format_money(amount, currency), license_keys: license.license_key })
  end

  def send_refund_email_later(license:)
    token = PortalToken.issue!(customer: self, product: license.product)
    LicenseEmailJob.perform_later(token, template: :refund_transactional_id,
      kind: "refund", reference_id: license.id)
  end

  def send_expiry_reminder_later(license:)
    token = PortalToken.issue!(customer: self, product: license.product)
    LicenseEmailJob.perform_later(token, template: :expiry_reminder_transactional_id,
      kind: "expiry", reference_id: license.id,
      data: { license_keys: license.license_key, expires_at: license.expires_at.to_date.to_s })
  end

  def subscribe_to_loops_later(product:)
    LoopsContactJob.perform_later(self, product, subscribed: true)
  end

  def unsubscribe_from_loops_later(product:)
    return if licenses.active.exists?(product:) # still an active customer of this product
    LoopsContactJob.perform_later(self, product, subscribed: false)
  end

  private
    # ponytail: string format, swap for number_to_currency if symbols needed
    def format_money(amount, currency)
      amount.nil? ? "" : "#{"%.2f" % (amount / 100.0)} #{currency.to_s.upcase}"
    end
end
