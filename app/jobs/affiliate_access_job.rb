class AffiliateAccessJob < ApplicationJob
  def perform(affiliate_token)
    return if affiliate_token.nil?
    affiliate = affiliate_token.affiliate
    product = Product.affiliate_mailer # global affiliate email ships through one configured product's Loops
    if product.nil?
      Rails.logger.warn("AffiliateAccessJob: no product has affiliate_transactional_id set; " \
        "skipping dashboard email for #{affiliate.email}")
      return
    end
    # ponytail: no Notification.once dedup — notifications.customer_id is NOT NULL and doesn't fit an
    # affiliate. The rate limit and reusable 30-min token already bound mail-bombing, and a duplicate
    # magic-link email is harmless. Add an affiliate_id column to notifications only if it bites.
    Loops.send_transactional(
      api_key: product.loops_api_key_or_default,
      transactional_id: product.affiliate_transactional_id,
      email: affiliate.email,
      data: {
        magic_link_url: url_helpers.affiliate_session_url(token: affiliate_token.token),
        affiliate_name: affiliate.name,
        sender_email: product.sender_email
      }
    )
  end

  private
    def url_helpers = Rails.application.routes.url_helpers
end
