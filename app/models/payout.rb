class Payout < ApplicationRecord
  belongs_to :affiliate

  validates :amount_cents, numericality: { greater_than: 0 }
  validates :currency, presence: true
  validates :paid_at, presence: true
end
