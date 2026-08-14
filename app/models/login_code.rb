class LoginCode < ApplicationRecord
  belongs_to :product

  # Six digits is 10^6 — small enough that the guess budget, not the hash, is what makes it
  # safe. Five tries against a ten-minute window is a 1-in-200,000 shot per code.
  MAX_ATTEMPTS = 5
  TTL = 10.minutes

  # `email` is already normalized (Purchase.normalize_email) — issuing on the raw spelling
  # would let one inbox hold several live codes under different spellings.
  # Returns [record, plaintext]: the plaintext exists only in memory, on its way to Loops.
  def self.issue!(product:, email:)
    # Requesting a new code retires the old one, so a code read from an older email can't
    # still be spent.
    where(product:, email:, consumed_at: nil)
      .update_all(consumed_at: Time.current, updated_at: Time.current)

    id = SecureRandom.uuid # minted here so the id can pepper its own hash, in one INSERT
    code = format("%06d", SecureRandom.random_number(10**6))
    record = create!(id:, product:, email:, code_hash: hash_code(id, code),
      expires_at: TTL.from_now)
    [ record, code ]
  end

  # secret_key_base is the pepper: it lives outside the database, so a leaked dump doesn't
  # hand anyone a working code. bcrypt would be theatre here — 10^6 candidates fall to any
  # cost factor, which is why MAX_ATTEMPTS, not the hash, is the real control.
  def self.hash_code(id, code)
    OpenSSL::Digest::SHA256.hexdigest("#{id}:#{code}:#{Rails.application.secret_key_base}")
  end

  # Returns :ok, :too_many_attempts, :code_expired or :code_invalid.
  #
  # The attempt is counted BEFORE anything else, so a crash, a timeout or a client that
  # hangs up mid-request still spends budget — otherwise the counter is bypassable by
  # abandoning the connection.
  def verify!(code)
    increment!(:attempts)

    if attempts > MAX_ATTEMPTS
      burn!
      :too_many_attempts
    elsif expires_at.past?
      :code_expired
    elsif consumed_at?
      :code_invalid
    elsif ActiveSupport::SecurityUtils.secure_compare(code_hash, self.class.hash_code(id, code.to_s))
      burn!
      :ok
    else
      :code_invalid
    end
  end

  private
    def burn! = update!(consumed_at: Time.current)
end
