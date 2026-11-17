# Apple's App Store Server Notifications V2. A one-time charge is recorded; a refund or a
# revocation marks that charge and revokes the license. Every other verified notification is
# acknowledged so Apple stops retrying it.
class Webhooks::AppStoreController < ActionController::API
  def create
    product = Product.find_by(id: params[:product_id]) or return head :not_found
    notification = AppStoreTransaction.verify_notification(params[:signedPayload])
    store_transaction = notification.transaction or return head :ok

    case notification.type
    when "ONE_TIME_CHARGE"
      product.app_store_charges.record!(store_transaction)
    when "REFUND", "REVOKE"
      product.app_store_charges.revoke!(store_transaction)
      # Scoped to THIS endpoint's product, as the Stripe webhook is. REFUND_REVERSED does not
      # restore the license, the same as a Stripe dispute we later win.
      License.revoke_from_app_store!(product, store_transaction) if store_transaction.for?(product)
    end
    head :ok
  rescue AppStoreTransaction::Invalid => error
    Rails.logger.info("iap.notification_refused reason=#{error.message} product=#{product.slug}")
    head :bad_request
  end
end
