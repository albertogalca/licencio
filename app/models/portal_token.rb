class PortalToken < ApplicationRecord
  belongs_to :customer
  belongs_to :product

  # Product-scoped magic-link token, reusable within its 30-minute window. One live token per
  # (customer, product), so requesting a link for product B never invalidates A's.
  #
  # Reusable (not single-use) on purpose: mail scanners and browser link-preloaders GET the URL
  # before the human clicks, so a one-shot token would be consumed by the prefetch and the real
  # click would fail. The 30-minute expiry bounds a leaked link instead.
  #
  # One upsert on the (customer, product) index, not find-then-save: two redemptions for one
  # new email at once both found nothing, both inserted, and the loser raised RecordNotUnique.
  def self.issue!(customer:, product:)
    upsert({ customer_id: customer.id, product_id: product.id,
             token: SecureRandom.urlsafe_base64(32), expires_at: 30.minutes.from_now },
           unique_by: %i[customer_id product_id])
    find_by!(customer:, product:)
  end

  def self.authenticate(token)
    where(expires_at: Time.current..).find_by(token:) if token.present?
  end
end
