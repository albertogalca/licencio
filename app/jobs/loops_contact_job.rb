class LoopsContactJob < ApplicationJob
  def perform(customer, product, subscribed:)
    api_key = product.loops_api_key_or_default
    if api_key.blank?
      Rails.logger.warn("LoopsContactJob: #{product.slug} has no Loops API key; " \
        "skipping contact sync for #{customer.email}")
      return
    end
    first, last = customer.name.to_s.split(/\s+/, 2)
    # Add buyers to the product's newsletter list on purchase only. Not on refund
    # (subscribed: false) — Loops rejects list adds for unsubscribed contacts anyway.
    mailing_lists = { product.loops_mailing_list_id => true } if subscribed && product.loops_mailing_list_id.present?
    Loops.upsert_contact(api_key:, email: customer.email, source: "Stripe",
      subscribed:, first_name: first, last_name: last, mailing_lists:)
  end
end
