class AffiliateToken < ApplicationRecord
  belongs_to :affiliate

  # Magic-link token, reusable within its 30-minute window (one live token per affiliate).
  # Reusable (not single-use) on purpose: mail scanners and browser link-preloaders GET the URL
  # before the human clicks, so a one-shot token would be consumed by the prefetch. The 30-minute
  # expiry bounds a leaked link instead.
  # ponytail: mirrors PortalToken. Extract a TokenAuthenticatable concern only if a third token type appears.
  def self.issue!(affiliate:)
    record = where(affiliate:).first_or_initialize
    record.update!(token: SecureRandom.urlsafe_base64(32), expires_at: 30.minutes.from_now)
    record
  end

  def self.authenticate(token)
    where(expires_at: Time.current..).find_by(token:) if token.present?
  end
end
