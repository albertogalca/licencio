# Where the card was issued, next to the country the site vouched for. The one signal a VPN
# cannot choose, recorded so the call on blocking mismatches is made from four weeks of numbers
# rather than a guess (decided 2026-10-19: record only, no Radar rule). Nothing waits on it.
class CardCountryJob < ApplicationJob
  discard_on Stripe::InvalidRequestError

  def perform(product, payment_intent)
    payment = Payment.find_by(stripe_payment_intent: payment_intent)
    return if payment.nil? || payment.card_country.present?
    country = product.card_country(payment_intent)
    payment.update!(card_country: country) if country
  end
end
