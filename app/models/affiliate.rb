class Affiliate < ApplicationRecord
  has_many :payments, dependent: :nullify
  has_many :payouts, dependent: :destroy
  has_many :affiliate_tokens, dependent: :delete_all

  enum :status, { pending: "pending", approved: "approved", rejected: "rejected" }

  normalizes :code, with: -> { it.to_s.downcase.strip }
  normalizes :email, with: -> { it.to_s.downcase.strip }

  validates :code, presence: true, uniqueness: true, format: { with: /\A[a-z0-9][a-z0-9-]*\z/,
    message: "may only contain lowercase letters, numbers and hyphens" }
  validates :name, presence: true
  validates :email, presence: true, uniqueness: true
  validates :commission_percent, numericality: { in: 0..100 }

  # Commission is frozen at sale time (stored on the Payment), so it's computed off the amount then,
  # never recomputed from commission_percent later — changing the rate never rewrites past sales.
  def commission_for(subtotal_cents) = subtotal_cents.to_i * commission_percent / 100

  # A code works on any product's checkout; the dashboard shows one suggested link per product.
  def referral_url(product) = "#{product.affiliate_landing_url}?ref=#{code}"

  def approve!
    update!(status: "approved")
    send_dashboard_access_later
  end

  # Emails the magic-link dashboard URL — only for an approved affiliate. Recovery and approval
  # both call this; a pending/rejected affiliate silently gets nothing (anti-enumeration).
  def send_dashboard_access_later
    return unless approved?
    token = AffiliateToken.issue!(affiliate: self)
    AffiliateAccessJob.perform_later(token)
  end
end
