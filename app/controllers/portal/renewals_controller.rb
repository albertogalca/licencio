class Portal::RenewalsController < Portal::BaseController
  def create
    # Scoped to the session's product AND customer — a Cozy session only renews Cozy licenses.
    license = current_product.licenses
      .where(customer_id: current_customer.id).find_by(id: params[:license_id])
    if license
      checkout = current_product.create_checkout_session(
        price_id: params.require(:price_id),
        email: current_customer.email,           # so fulfillment matches this customer → renew!
        renew_license_key: license.license_key)   # tags the checkout as a renewal of THIS license
      redirect_to checkout.url, allow_other_host: true, status: :see_other
    else
      redirect_to portal_root_path, alert: "That license could not be found."
    end
  rescue Product::CheckoutNotConfigured, ActiveRecord::RecordNotFound, Stripe::StripeError
    # RecordNotFound also covers a tampered price_id from another product (create_checkout_session
    # raises it when price.product != stripe_product_id).
    redirect_to portal_root_path, alert: "Renewal is temporarily unavailable — please try again."
  end
end
