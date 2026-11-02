require "csv"

# A prepaid code from a deal site (AppSumo). The site sells the codes and hands them out; a
# buyer types one at /redeem with their email and gets a license, or one more seat on the
# license that email already has. The key never changes, so a stacked buyer keeps the key they
# already pasted into the app.
#
# Only a digest is stored. Plaintext exists twice: on stdout when the codes are generated, and
# in the deal site's spreadsheet. A leaked database hands out no redeemable code.
class RedemptionCode < ApplicationRecord
  belongs_to :product
  belongs_to :customer, optional: true
  belongs_to :license, optional: true

  enum :status, { unredeemed: "unredeemed", redeemed: "redeemed", revoked: "revoked" }
  enum :source, { appsumo: "appsumo" }

  # What one code buys, per source. One AppSumo code is the 1 Mac plan, with updates forever,
  # and an email can stack 4 of them onto the same key.
  DEALS = {
    "appsumo" => { seats: 1, per_customer: 4, update_policy: "lifetime" }
  }.freeze

  # Uppercase and digits without 0/O, 1/I/L: 31 symbols, so 16 of them are about 79 bits.
  ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789".chars.freeze
  LENGTH = 16
  # What AppSumo accepts in an uploaded code list.
  IMPORT_LENGTHS = 3..200

  Invalid = Class.new(StandardError)
  class StackLimitReached < StandardError
    attr_reader :limit

    def initialize(limit)
      @limit = limit
      super("stack limit of #{limit} reached")
    end
  end

  scope :search, ->(term) {
    term = term.to_s.strip
    where(code_digest: digest(term)).or(where(customer_id: Customer.search(term).select(:id)))
  }

  # Forgiving about what people paste: case, spaces and dashes don't matter.
  def self.normalize(raw) = raw.to_s.upcase.gsub(/[\s-]/, "")

  def self.digest(raw) = OpenSSL::Digest::SHA256.hexdigest(normalize(raw))

  def self.find_by_code(raw) = find_by(code_digest: digest(raw))

  def self.deal(source) = DEALS.fetch(source.to_s)

  # { [product_id, source] => { "unredeemed" => n, "redeemed" => n, "revoked" => n } }
  def self.pool_stats
    group(:product_id, :source, :status).count
      .each_with_object(Hash.new { |h, k| h[k] = Hash.new(0) }) do |((product_id, source, status), n), stats|
        stats[[ product_id, source ]][status] += n
      end
  end

  # The pool is thousands of unused codes, so by default only the ones in use are listed. A
  # search or a status filter shows whatever it matches.
  def self.listed(q: nil, status: nil)
    scope = q.present? ? search(q) : all
    if status.present? then scope.where(status:)
    elsif q.blank? then scope.where.not(status: "unredeemed")
    else scope
    end
  end

  # Returns the plaintext codes in random order. The only time they exist on this server.
  # A collision with a code already in the pool is skipped by the unique digest and replaced.
  def self.generate!(product:, source: "appsumo", count: 10_000)
    deal(source)
    codes = {}
    while codes.size < count
      fresh = Array.new(count - codes.size) { random_code }.uniq.index_by { digest(it) }.except(*codes.keys)
      codes.merge!(insert_codes(product, source, fresh))
    end
    codes.values.shuffle
  end

  # One code per line, no header, as AppSumo exports them. Returns a tally to print.
  def self.import!(product:, io:, source: "appsumo")
    deal(source)
    tally = Hash.new(0)
    CSV.new(io).each_slice(1_000) do |rows|
      codes = rows.filter_map { |row| normalize(row.first).presence }
      valid, invalid = codes.partition { IMPORT_LENGTHS.cover?(it.length) }
      tally[:invalid] += invalid.size + (rows.size - codes.size)
      batch = valid.index_by { digest(it) }
      added = insert_codes(product, source, batch).size
      tally[:imported] += added
      tally[:duplicates] += valid.size - added
    end
    tally
  end

  # Raises Invalid for an unknown, used or revoked code alike, so a caller learns nothing about
  # which. Locks the customer first, then the code: two different codes for one email queue up
  # behind each other, so neither the stack limit nor a first license can be doubled.
  def self.redeem!(raw, email:)
    digest = digest(raw)
    # Junk codes write nothing, not even a customer row.
    raise Invalid unless find_by(code_digest: digest)&.unredeemed?
    customer = Customer.with_email(email) || Customer.upsert!(email:)

    code = transaction do
      customer.lock!
      code = lock.find_by(code_digest: digest)
      raise Invalid unless code&.unredeemed?
      code.send(:apply_to!, customer)
    end
    code.deliver_later
    code
  end

  def self.random_code = Array.new(LENGTH) { ALPHABET.sample(random: SecureRandom) }.join

  # Returns the subset of { digest => code } that was new to the pool.
  def self.insert_codes(product, source, codes)
    return {} if codes.empty?
    rows = codes.map do |digest, code|
      { product_id: product.id, source:, code_digest: digest, code_hint: code.last(4), status: "unredeemed" }
    end
    inserted = insert_all(rows, unique_by: :code_digest, returning: :code_digest).rows.flatten
    codes.slice(*inserted)
  end
  private_class_method :insert_codes

  def deal = self.class.deal(source)

  # True when this redemption minted the license instead of adding a seat to one. Set only on
  # the instance redeem! returns; a reloaded record answers nil.
  def issued_license? = @issued_license

  def deliver_later
    customer.send_redemption_email_later(license:, reference_id: id, issued: issued_license?)
    customer.subscribe_to_loops_later(product:, newsletter: false) if issued_license?
  end

  # An AppSumo refund. Takes back the seat this code added, and the devices that no longer fit.
  # Idempotent: revoking a revoked code does nothing.
  def revoke!
    with_lock do
      next if revoked?
      license.remove_seats!(deal[:seats]) if redeemed? && license
      update!(status: "revoked", revoked_at: Time.current)
      Rails.logger.info("[redemption] revoked code #{id} (license #{license_id || "none"})")
    end
  end

  private
    # Only safe inside redeem!, which holds the customer and code locks the stack limit needs.
    def apply_to!(customer)
      redeemed_before = self.class.redeemed.where(product:, source:, customer:).count
      raise StackLimitReached.new(deal[:per_customer]) if redeemed_before >= deal[:per_customer]

      target = stack_target(customer)
      if target
        target.add_seats!(deal[:seats])
      else
        @issued_license = true
        target = product.issue_license!(customer:, quantity: deal[:seats], stripe_payment_id: nil,
          update_policy: deal[:update_policy])
      end
      update!(status: "redeemed", customer:, license: target, redeemed_at: Time.current)
      self
    end

    # The license earlier codes went to, so every code stacks on one key. Else the customer's
    # own license for this product, however it was bought. A trial is not a license to stack on.
    def stack_target(customer)
      previous = self.class.redeemed.where(product:, customer:).where.not(license_id: nil)
        .order(:redeemed_at).last&.license
      return previous if previous&.active?
      customer.licenses.active.where(product:, trial: false).order(:created_at).first
    end
end
