class MagicLinkJob < ApplicationJob
  def perform(customer, product)
    Loops.send_transactional(
      api_key: product.loops_api_key_or_default,
      transactional_id: product.loops_magic_link_transactional_id,
      email: customer.email,
      data: {
        magic_link_url: url_helpers.portal_session_url(token: customer.auth_token),
        product_name: product.name,
        sender_email: product.sender_email,
        # Only this product's keys — a Cozy email never lists Picmal keys.
        license_keys: product.licenses.where(customer:).pluck(:license_key).join("\n")
      }
    )
  end

  private
    def url_helpers = Rails.application.routes.url_helpers
end
