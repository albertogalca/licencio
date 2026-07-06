class LicenseDeliveryJob < ApplicationJob
  # Emails the buyer their license key after a purchase (or renewal).
  def perform(license)
    product = license.product
    return if license.customer.nil? || product.loops_transactional_id.blank?
    Loops.send_transactional(
      api_key: product.loops_api_key_or_default,
      transactional_id: product.loops_transactional_id,
      email: license.customer.email,
      data: {
        license_key: license.license_key,
        product_name: product.name,
        sender_email: product.sender_email
      }
    )
  end
end
