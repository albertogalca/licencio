class LicenseEmailJob < ApplicationJob
  def perform(portal_token, template:, data: {})
    return if portal_token.nil?
    customer = portal_token.customer
    product  = portal_token.product
    transactional_id = product.public_send(template)
    if transactional_id.blank?
      Rails.logger.warn("LicenseEmailJob: #{product.slug} has no #{template}; " \
        "skipping email for #{customer.email}")
      return
    end
    Loops.send_transactional(
      api_key: product.loops_api_key_or_default,
      transactional_id:,
      email: customer.email,
      # Base variables every template can use; callers override via `data`
      # (e.g. amount, expires_at, or a single license_key).
      data: {
        product_name: product.name,
        license_keys: product.licenses.where(customer:).pluck(:license_key).join("\n"),
        magic_link_url: url_helpers.portal_session_url(token: portal_token.token, product: product.slug),
        sender_email: product.sender_email
      }.merge(data)
    )
  end

  private
    def url_helpers = Rails.application.routes.url_helpers
end
