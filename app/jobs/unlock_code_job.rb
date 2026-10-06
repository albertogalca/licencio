# Where the "does this address own anything?" question actually gets asked. It lives here,
# behind the queue, so /v1/unlock/request answers in constant time no matter what the answer
# is — a caller can't tell a buyer from a stranger by watching the clock.
#
# Returns the LoginCode when one was mailed, nil when there was nothing to mail (support's
# lookup uses that to report code_sent).
class UnlockCodeJob < ApplicationJob
  def perform(product, raw_email)
    return if product.nil?
    # App Review unlocks with the fixed code and the address has no inbox: every code
    # mailed there was a hard bounce on the sending domain.
    return if review_address?(raw_email)

    purchase = Purchase.for_email(product, raw_email).live.order(:purchased_at).last
    return if purchase.nil?

    record, code = LoginCode.issue!(product:, email: Purchase.normalize_email(raw_email))

    # Mailed to the address ON THE PURCHASE, not the one that was typed. They normalize to
    # the same inbox by our rules, but "bob+x@corp.com" only reaches bob at providers that
    # honour plus-addressing — send to the address that actually paid and it always lands.
    Loops.send_transactional(
      api_key: product.loops_api_key_or_default,
      transactional_id: product.unlock_transactional_id,
      email: purchase.email,
      data: {
        code: code,
        product_name: product.name
      }
    )
    record
  end

  private
    def review_address?(raw_email)
      review_email = ENV["REVIEW_UNLOCK_EMAIL"].to_s
      review_email.present? && Purchase.normalize_email(raw_email) == Purchase.normalize_email(review_email)
    end
end
