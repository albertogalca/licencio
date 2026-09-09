class StudentDiscountJob < ApplicationJob
  def perform(product, email)
    return if product.nil? || !product.student_discount?

    # A student isn't a buyer yet, but Customer is what Notification dedups on, and a
    # customer with no license never reaches Product#customers (it goes through
    # licenses), so this can't inflate the storefront's "trusted by N".
    customer = Customer.upsert!(email:)

    # One code per address per product per day. The endpoint is public, so the per-IP
    # rate limit alone would still let a botnet bury one inbox. The slug is in the key
    # because a student buying both apps asks twice on the same day, and a date-only key
    # silently swallowed the second request and left them holding the first app's code.
    Notification.once(customer:, kind: "student_discount", reference_id: "#{product.slug}:#{Date.current}") do
      Loops.send_transactional(
        api_key: product.loops_api_key_or_default,
        transactional_id: product.student_transactional_id,
        email: email,
        data: {
          discount_code: product.student_discount_code,
          pricing_url: product.checkout_cancel_url,
          product_name: product.name,
          sender_email: product.sender_email
        }
      )
    end
  end
end
