class Purchase < ApplicationRecord
  belongs_to :product

  # standard = a year of updates, forever = every update there will ever be. Neither ever
  # stops the app working: this is a one-time purchase, and nothing here expires.
  enum :tier, { standard: "standard", forever: "forever" }

  # Gmail treats a.b+tag@gmail.com and ab@gmail.com as the same mailbox; nobody else does
  # (dots are significant at, say, fastmail). So dots are stripped for Google domains only,
  # and the +tag everywhere, because plus-addressing is universal. Someone who buys as
  # "Ana.Perez+cozy@Gmail.com" and later types "anaperez@gmail.com" must still unlock.
  #
  # MUST stay byte-identical to NORMALIZED_EMAIL_SQL below — PurchaseTest asserts the two
  # agree over a fixture list, because a disagreement is a customer who can't unlock what
  # they paid for.
  GOOGLE_DOMAINS = %w[gmail.com googlemail.com].freeze

  NORMALIZED_EMAIL_SQL = <<~SQL.squish
    CASE WHEN split_part(lower(btrim(email)), '@', 2) IN ('gmail.com','googlemail.com')
         THEN replace(split_part(split_part(lower(btrim(email)), '@', 1), '+', 1), '.', '')
         ELSE split_part(split_part(lower(btrim(email)), '@', 1), '+', 1)
    END || '@' || split_part(lower(btrim(email)), '@', 2)
  SQL

  # split_part semantics, not String#partition: Postgres reads "a@b@c" as local "a",
  # domain "b", and the Ruby side has to agree even on inputs nobody should ever type.
  def self.normalize_email(raw)
    value  = raw.to_s.strip.downcase
    domain = value.split("@", -1)[1].to_s
    local  = value.split("@", -1)[0].to_s.split("+", -1)[0].to_s
    local  = local.delete(".") if GOOGLE_DOMAINS.include?(domain)
    "#{local}@#{domain}"
  end

  scope :live, -> { where(refunded_at: nil) }

  # Matches on the normalized form via the expression index, so the buyer can type their
  # address however they remember it.
  scope :for_email, ->(product, raw) {
    where(product:).where("#{NORMALIZED_EMAIL_SQL} = ?", normalize_email(raw))
  }

  # Recorded alongside (never instead of) license fulfillment — the license-key system is
  # untouched and keeps working. `price` is the purchased line item; its metadata `tier` is
  # what opts a product into the unlock flow at all, so a product that doesn't tag its
  # prices (picmal) silently records nothing.
  def self.record_stripe!(product, session, price:)
    tier = price && price.metadata["tier"].presence
    return unless tier.in?(tiers.values)
    # The same tag check fulfillment makes: a session explicitly addressed to another
    # product never writes here either, however it was signed.
    tag = session.metadata["licencio_product_id"].presence
    return if tag && tag.to_s != product.id.to_s

    purchased_at = Time.current
    # Stripe delivers at least once; the unique index turns a redelivery into a find.
    create_or_find_by!(provider: "stripe",
                       provider_order_id: session.payment_intent || session.id) do |purchase|
      purchase.product = product
      purchase.email = session.customer_details.email
      purchase.tier = tier
      purchase.purchased_at = purchased_at
      purchase.updates_until = (purchased_at + 1.year).to_date if tier == "standard"
    end
  end

  # Idempotent: `live` means a redelivered charge.refunded finds nothing to do.
  def self.refund!(product:, provider_order_id:)
    live.find_by(product:, provider_order_id:)&.update!(refunded_at: Time.current)
  end

  # The entitlement, as signed. Deliberately has NO `exp`: the promise is that the app
  # keeps working forever, offline, and a token that expires is not that promise. `device`
  # is echoed from the request purely so a token can be told apart from another device's —
  # it is never stored, and never limits how many devices unlock.
  def token_claims(device_id:)
    { v: 1, sub: id, tier:, updates_until: updates_until&.iso8601,
      device: device_id, iat: Time.current.iso8601 }
  end

  # One-time migration of the existing license-key customers onto purchases, so the new
  # unlock flow works for people who bought before it existed. Idempotent — the unique
  # index makes a second run a no-op. Returns a tally for the rake task to print.
  def self.backfill_from_licenses!(product, dry_run: false)
    counts = Hash.new(0)
    product.licenses.where(trial: false).where.not(customer_id: nil)
      .includes(:customer).find_each do |license|
      attrs = backfill_attributes(license)
      if attrs.nil?
        counts[:skipped] += 1
      elsif dry_run
        counts[exists?(attrs.slice(:provider, :provider_order_id)) ? :existing : :created] += 1
      else
        purchase = create_or_find_by!(attrs.slice(:provider, :provider_order_id)) do |record|
          record.assign_attributes(attrs)
        end
        counts[purchase.previously_new_record? ? :created : :existing] += 1
      end
    end
    counts
  end

  # nil when the license says nothing about updates (a versioned or policy-less license
  # with no expiry) — better skipped and reported than guessed at.
  def self.backfill_attributes(license)
    tier =
      if license.effective_update_policy == "lifetime" then "forever"
      elsif license.expires_at.present?                then "standard"
      end
    return if tier.nil?

    { product_id: license.product_id, email: license.customer.email, tier:,
      purchased_at: license.claimed_at || license.created_at,
      updates_until: (license.expires_at.to_date if tier == "standard"),
      provider: license.migration_source || "stripe",
      # An imported license has no payment id; its key is the only stable order handle.
      provider_order_id: license.stripe_payment_id || "license:#{license.license_key}",
      refunded_at: (license.updated_at if license.refunded?) }
  end
end
