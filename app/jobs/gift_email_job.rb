# The card, sent to the buyer. Theirs to print, forward, or keep for the day.
class GiftEmailJob < ApplicationJob
  def perform(gift)
    product = gift.product
    if product.gift_transactional_id.blank?
      Rails.logger.warn("GiftEmailJob: #{product.slug} has no gift_transactional_id; " \
        "skipping the card for gift #{gift.id}")
      return
    end
    # emailed_at under the row lock, so a retry after a delivered send doesn't mail it twice.
    gift.with_lock do
      next if gift.emailed_at
      Loops.send_transactional(
        api_key: product.loops_api_key_or_default,
        transactional_id: product.gift_transactional_id,
        email: gift.buyer_email,
        data: { product_name: product.name, card_url: gift.card_url, gift_code: gift.display_code,
                to_name: gift.to_name.to_s, sender_email: product.sender_email })
      gift.update!(emailed_at: Time.current)
    end
  end
end
