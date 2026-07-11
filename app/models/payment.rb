class Payment < ApplicationRecord
  belongs_to :license
  belongs_to :affiliate, optional: true

  # A purchase mints a license; a renewal extends one. The unique index on
  # stripe_payment_intent is the idempotency backbone for Stripe's at-least-once delivery.
  enum :kind, { purchase: "purchase", renewal: "renewal" }, prefix: true

  validates :stripe_payment_intent, presence: true, uniqueness: true

  # Commission ledger. Only original purchases carry an affiliate (renewals never do).
  scope :commissionable, -> { kind_purchase.where.not(affiliate_id: nil) }
  # Payable = commission cleared its 30-day refund hold and the license wasn't refunded.
  scope :payable, -> { commissionable.where(created_at: ..30.days.ago)
                         .joins(:license).where.not(licenses: { status: "refunded" }) }
end
