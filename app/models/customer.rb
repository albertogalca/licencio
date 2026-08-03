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
    # Deduped on the payment, not the license: a renewal reuses the same license row, so keying
    # on the license id would let the original purchase's receipt swallow every renewal receipt.
    LicenseEmailJob.perform_later(token, template: :purchase_transactional_id,
      kind: "purchase", reference_id: license.stripe_payment_id || license.id,
      data: { amount: format_money(amount, currency), license_keys: license.license_key })
  end

  def send_refund_email_later(license:)
    token = PortalToken.issue!(customer: self, product: license.product)
    LicenseEmailJob.perform_later(token, template: :refund_transactional_id,
      kind: "refund", reference_id: license.id)
  end

  # Deduped per expiry cycle, not per license: renew! moves expires_at, so next year's reminder
  # is a different one-shot rather than one the first year already spent.
  def send_expiry_reminder_later(license:)
    token = PortalToken.issue!(customer: self, product: license.product)
    LicenseEmailJob.perform_later(token, template: :expiry_reminder_transactional_id,
      kind: "expiry", reference_id: license.expiry_reference,
      data: { license_keys: license.license_key,
              expires_at: license.expires_at.to_date.strftime("%B %-d, %Y"),
              renew_url: renew_url_for(license) })
  end

  def subscribe_to_loops_later(product:)
    LoopsContactJob.perform_later(self, product, subscribed: true)
  end

  # The license that decides what this customer is entitled to for a product, when they hold
  # more than one: a lifetime license outranks any dated one, otherwise the longest window
  # wins. That's the pair of facts the renewal emails filter on.
  def primary_license(product)
    licenses.active.where(product:).max_by do |license|
      [ license.effective_update_policy == "lifetime" ? 1 : 0, license.expires_at&.to_i || 0 ]
    end
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

    # Public and key-based, so it still works when the email is read days later and the
    # magic link in the same message has long expired.
    def renew_url_for(license)
      Rails.application.routes.url_helpers.new_portal_renewal_url(
        license_key: license.license_key, product: license.product.slug)
    end
end
