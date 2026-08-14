class Affiliate < ApplicationRecord
  has_many :payments, dependent: :nullify
  has_many :payouts, dependent: :destroy
  has_many :affiliate_tokens, dependent: :delete_all

  enum :status, { pending: "pending", approved: "approved", rejected: "rejected" }

  normalizes :code, with: -> { it.to_s.downcase.strip }
  normalizes :email, with: -> { it.to_s.downcase.strip }

  # Signup is public and uniqueness spans every status, so a pending application that will
  # never be approved still locks a code forever. Keep the names that would be confusing or
  # valuable in a published ?ref= URL out of the land grab.
  RESERVED_CODES = %w[admin affiliate app apps buy checkout deal deals discount download
    help official picmal cozy lumiv promo sale store student support team]

  validates :code, presence: true, uniqueness: true, format: { with: /\A[a-z0-9][a-z0-9-]*\z/,
    message: "may only contain lowercase letters, numbers and hyphens" },
    exclusion: { in: ->(_) { RESERVED_CODES + Product.pluck(:slug) }, message: "is reserved" }
  validates :name, presence: true
  validates :email, presence: true, uniqueness: true
  validates :commission_percent, numericality: { in: 0..100 }

  # Commission is frozen at sale time (stored on the Payment), so it's computed off the amount then,
  # never recomputed from commission_percent later — changing the rate never rewrites past sales.
  # percent: overrides the affiliate's own rate (per-product override); nil → the affiliate's rate.
  def commission_for(subtotal_cents, percent: nil) = subtotal_cents.to_i * (percent || commission_percent) / 100

  # A referral to yourself is a personal discount, not a referral. Without this an approved
  # affiliate appends their own ?ref= to their own purchase and earns the commission back on
  # it, every time — and at scale buys at 20% off to resell under the storefront price. Both
  # addresses count: the one they signed up with and the one that gets paid. Normalized
  # through Purchase, so +tags and gmail dots don't dodge it.
  def self_referral?(buyer_email)
    return false if buyer_email.blank?
    bought_by = Purchase.normalize_email(buyer_email)
    [ email, payout_email ].compact_blank.any? { |own| Purchase.normalize_email(own) == bought_by }
  end

  # A code works on any product's checkout; the dashboard shows one suggested link per product.
  def referral_url(product) = "#{product.affiliate_landing_url}?ref=#{code}"

  # The rate a sale of this product actually pays — the same fallback License#purchase uses.
  # Rates are per-product, so no single number is correct for the affiliate as a whole.
  def commission_percent_for(product) = product.affiliate_commission_percent || commission_percent

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
