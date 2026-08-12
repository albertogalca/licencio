class StudentDiscountJob < ApplicationJob
  def perform(product, email)
    return if product.nil? || !product.student_discount?

    # A student isn't a buyer yet, but Customer is what Notification dedups on, and a
    # customer with no license never reaches Product#customers (it goes through
    # licenses), so this can't inflate the storefront's "trusted by N".
    customer = Customer.upsert!(email:)

    # One code per address per day. The endpoint is public, so the per-IP rate limit
    # alone would still let a botnet bury one inbox.
    Notification.once(customer:, kind: "student_discount", reference_id: Date.current.to_s) do
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
