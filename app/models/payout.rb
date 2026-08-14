class Payout < ApplicationRecord
  belongs_to :affiliate

  validates :amount_cents, numericality: { greater_than: 0 }
  validates :currency, presence: true
  validates :paid_at, presence: true

  # The one place a number typed by a human becomes a financial record. The admin page shows
  # what is owed but never enforced it, so a double-clicked form or a slipped digit wrote a
  # second (or oversized) row and the ledger quietly went negative. Bound it server-side.
  validate :within_amount_owed, on: :create

  private
    def within_amount_owed
      return if amount_cents.to_i <= 0 # numericality already objects
      owed = affiliate.payments.payable.sum(:commission_cents) - affiliate.payouts.sum(:amount_cents)
      return if amount_cents.to_i <= owed
      errors.add(:amount_cents, "is more than the #{owed} cents currently owed")
    end
end
