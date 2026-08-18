class Payment < ApplicationRecord
  belongs_to :license

  # A purchase mints a license; a renewal extends one; an upgrade adds seats to one. The unique
  # index on stripe_payment_intent is the idempotency backbone for Stripe's at-least-once delivery.
  enum :kind, { purchase: "purchase", renewal: "renewal", upgrade: "upgrade" }, prefix: true

  validates :stripe_payment_intent, presence: true, uniqueness: true
end
