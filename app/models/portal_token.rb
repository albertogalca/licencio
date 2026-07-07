class PortalToken < ApplicationRecord
  belongs_to :customer
  belongs_to :product

  # Product-scoped magic-link token, reusable within its 30-minute window. One live token per
  # (customer, product), so requesting a link for product B never invalidates A's.
  def self.issue!(customer:, product:)
    record = where(customer:, product:).first_or_initialize
    record.update!(token: SecureRandom.urlsafe_base64(32), expires_at: 30.minutes.from_now)
    record
  end

  def self.authenticate(token)
    where(expires_at: Time.current..).find_by(token:) if token.present?
  end
end
