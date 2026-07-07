class Portal::RenewalsController < Portal::BaseController
  def create
    # Scoped to the session's product AND customer — a Cozy session only renews Cozy licenses.
    license = current_product.licenses
      .where(customer_id: current_customer.id).find_by(id: params[:license_id])
    return redirect_to(portal_root_path, alert: "That license could not be found.") unless license

    price_id = renewal_price_id(license)
    return redirect_to(portal_root_path, alert: "Renewal isn't available for this license.") unless price_id

    checkout = current_product.create_checkout_session(
      price_id:,
      email: current_customer.email,           # so fulfillment matches this customer → renew!
      renew_license_key: license.license_key)   # tags the checkout as a renewal of THIS license
    redirect_to checkout.url, allow_other_host: true, status: :see_other
  rescue Product::CheckoutNotConfigured, ActiveRecord::RecordNotFound, Stripe::StripeError
    redirect_to portal_root_path, alert: "Renewal is temporarily unavailable — please try again."
  end

  private
    # Renew at the license's OWN purchased price, chosen server-side — never a client-supplied
    # price_id, so a customer can't renew a paid tier through a cheaper price's checkout. Imported
    # licenses (no stored price) fall back to the variant matching their seat count, then cheapest.
    def renewal_price_id(license)
      return license.stripe_price_id if license.stripe_price_id.present?
      variants = current_product.variants
      (variants.find { |v| v.seats == license.max_activations } || variants.min_by(&:amount_cents))&.price_id
    end
end
