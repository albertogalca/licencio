# A license bought for somebody else. The checkout mints nothing: it leaves a code here, and
# the buyer gets a card to print or forward. Whoever types the code with their own address
# gets the license and the unlock-by-email purchase, exactly as if they had bought it, so the
# iPhone unlock (which matches the purchase email) works for them and never for the buyer.
#
# Refunds keep working through the payment intent: before redemption it voids the code, after
# it License.refund! and Purchase.refund! find the rows redeem! wrote under the same intent.
class Gift < ApplicationRecord
  belongs_to :product
  belongs_to :license, optional: true

  # Crockford base32: no I, L, O or U, so a code read off paper has nothing to confuse. 12
  # characters is 60 bits, far past guessing behind the rate limits on the public endpoints.
  ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ".chars.freeze
  CODE_LENGTH = 12

  # Shown on the card and typed back from it. Stripe caps a text field at 255.
  TEXT_LIMITS = { to_name: 40, from_name: 40, note: 240 }.freeze

  # Carries the state the gift is in, which names the error the card page shows.
  class Unavailable < StandardError
    attr_reader :state

    def initialize(state)
      @state = state
      super("gift is #{state}")
    end
  end

  # The checkout's custom field keys (Product::GIFT_FIELDS), and where each one is stored.
  FIELD_ATTRIBUTES = { "to" => :to_name, "from" => :from_name, "note" => :note }.freeze

  before_validation :assign_code, on: :create
  validates :code, :buyer_email, :stripe_session_id, :stripe_payment_intent, presence: true

  def self.requested?(session) = session.metadata["gift"] == "1"

  # Stripe delivers at least once; the unique intent turns a redelivery into a find, and only
  # the first delivery mails the card.
  def self.create_from_stripe_session!(product, session)
    meta = session.metadata
    return if meta["licencio_product_id"].to_s != product.id.to_s

    price = product.session_price(session)
    fields = custom_field_values(session)
    gift = create_or_find_by!(stripe_payment_intent: session.payment_intent || session.id) do |record|
      record.assign_attributes(
        product:, stripe_session_id: session.id,
        buyer_email: session.customer_details.email,
        price_id: meta["price_id"].presence || price&.id,
        quantity: meta["quantity"].presence&.to_i || (product.seats_for(price) if price),
        update_policy: meta["update_policy"].presence || (price.metadata["update_policy"] if price),
        tier: (price.metadata["tier"].presence if price),
        regional_band: meta["regional_band"].presence&.to_i,
        regional_country: meta["regional_country"].presence,
        amount_cents: session.amount_total, currency: session.currency,
        **fields)
    end
    GiftEmailJob.perform_later(gift) if gift.previously_new_record?
    gift
  end

  # Read through to_hash: a session whose fields were all left empty can omit `text` entirely.
  def self.custom_field_values(session)
    Array(session.to_hash[:custom_fields]).each_with_object({}) do |field, values|
      attribute = FIELD_ATTRIBUTES[field[:key]] or next
      values[attribute] = field.dig(:text, :value).to_s.squish.first(TEXT_LIMITS[attribute]).presence
    end
  end
  private_class_method :custom_field_values

  # Forgiving on purpose: dashes, spaces, lowercase and the letters people mistake for digits
  # all read back as the code printed on the card.
  def self.normalize_code(raw)
    raw.to_s.upcase.tr("OIL", "011").gsub(/[^0-9A-Z]/, "")
  end

  def self.find_by_code(raw) = find_by(code: normalize_code(raw))

  # Idempotent: a redelivered charge.refunded finds the gift already void. Locks the row, so a
  # refund racing a redemption waits for it and then finds the license redeem! wrote.
  def self.refund!(product:, payment_intent:)
    gift = product.gifts.find_by(stripe_payment_intent: payment_intent) or return
    gift.with_lock { gift.update!(refunded_at: Time.current) if gift.refunded_at.nil? }
  end

  # The card as the storefront shows it. Never the buyer's address.
  def card
    { code: display_code, tier:, to: to_name, from: from_name, note:, state: }
  end

  def state
    if refunded_at then "refunded"
    elsif redeemed_at then "redeemed"
    else "ready"
    end
  end

  def display_code = code.scan(/.{4}/).join("-")

  # The code rides in the fragment, so it never reaches a server log or a Referer header.
  def card_url = "#{product.gift_card_url}##{display_code}"

  # The recipient becomes the customer: license, receipt, portal and unlock all follow their
  # address. The buyer's Stripe customer stays off the license, so a renewal a year from now
  # never prefills the buyer's email.
  def redeem!(email:)
    raise Unavailable, state unless state == "ready"
    customer = Customer.upsert!(email:)
    with_lock do
      raise Unavailable, state unless state == "ready"
      issued = product.issue_license!(customer:, quantity:, stripe_payment_id: stripe_payment_intent,
        price_id:, amount_cents:, currency:, update_policy:, regional_band:, regional_country:)
      Purchase.record_gift!(self, email:)
      update!(license: issued, redeemed_at: Time.current)
    end
    # The payment exists only now, so this is the first moment the card's country has a row to
    # go on. A free gift (no payment intent) has no card to read.
    if product.regional_pricing? && stripe_payment_intent.start_with?("pi_")
      CardCountryJob.perform_later(product, stripe_payment_intent)
    end
    # The receipt template prints an amount; a present arrives without its price.
    customer.send_purchase_email_later(license:, amount: nil, currency: nil)
    # They never ticked a box, so they land in Loops as a customer, not on the newsletter.
    customer.subscribe_to_loops_later(product:, newsletter: false)
    license
  end

  private
    def assign_code
      self.code ||= Array.new(CODE_LENGTH) { ALPHABET.sample(random: SecureRandom) }.join
    end
end
