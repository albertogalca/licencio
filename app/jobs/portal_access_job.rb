class PortalAccessJob < ApplicationJob
  def perform(portal_token)
    return if portal_token.nil?
    customer = portal_token.customer
    product  = portal_token.product
    if product.loops_transactional_id.blank?
      Rails.logger.warn("PortalAccessJob: #{product.slug} has no loops_transactional_id; " \
        "skipping portal email for #{customer.email}")
      return
    end
    Loops.send_transactional(
      api_key: product.loops_api_key_or_default,
      transactional_id: product.loops_transactional_id,
      email: customer.email,
      data: {
        magic_link_url: url_helpers.portal_session_url(token: portal_token.token, product: product.slug),
        license_keys: product.licenses.where(customer:).pluck(:license_key).join("\n"),
        product_name: product.name,
        sender_email: product.sender_email
      }
    )
  end

  private
    def url_helpers = Rails.application.routes.url_helpers
end
