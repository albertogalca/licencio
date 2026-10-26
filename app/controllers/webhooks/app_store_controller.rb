# Apple's App Store Server Notifications V2. Only a refund or a revocation changes anything
# here; every other verified notification is acknowledged so Apple stops retrying it.
class Webhooks::AppStoreController < ActionController::API
  def create
    product = Product.find_by(id: params[:product_id]) or return head :not_found
    notification = AppStoreTransaction.verify_notification(params[:signedPayload])
    store_transaction = notification.transaction
    # Scoped to THIS endpoint's product, as the Stripe webhook is. REFUND_REVERSED does not
    # restore the license, the same as a Stripe dispute we later win.
    if notification.type.in?(%w[REFUND REVOKE]) && store_transaction&.for?(product)
      License.revoke_from_app_store!(product, store_transaction)
    end
    head :ok
  rescue AppStoreTransaction::Invalid => error
    Rails.logger.info("iap.notification_refused reason=#{error.message} product=#{product.slug}")
    head :bad_request
  end
end
