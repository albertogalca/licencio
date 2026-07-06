class PortalAccessJob < ApplicationJob
  # One email = this product's license key(s) + a portal sign-in link. Sent on purchase and on recovery.
  # The magic link is scoped to the product, so a Cozy email only ever opens the Cozy portal view.
  def perform(customer, product)
    return if customer.nil? || product.loops_transactional_id.blank?
    Loops.send_transactional(
      api_key: product.loops_api_key_or_default,
      transactional_id: product.loops_transactional_id,
      email: customer.email,
      data: {
        magic_link_url: url_helpers.portal_session_url(token: customer.auth_token, product: product.slug),
        license_keys: product.licenses.where(customer:).pluck(:license_key).join("\n"),
        product_name: product.name,
        sender_email: product.sender_email
      }
    )
  end

  private
    def url_helpers = Rails.application.routes.url_helpers
end
