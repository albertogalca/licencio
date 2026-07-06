class Api::CheckoutsController < ActionController::API
  rescue_from ActiveRecord::RecordNotFound, with: -> { head :not_found }

  def create
    product = Product.find_by!(slug: params[:product_slug])
    price   = Stripe::Price.retrieve(params.require(:price_id))
    raise ActiveRecord::RecordNotFound unless price.product == product.stripe_product_id
    seats   = (price.metadata["seats"] || product.max_activations_default).to_i
    session = Stripe::Checkout::Session.create(
      mode: "payment", customer_creation: "always",
      line_items: [ { price: price.id, quantity: 1 } ],
      customer_email: params[:email].presence,
      metadata: { licencio_product_id: product.id, quantity: seats,
                  renew_license_key: params[:renew_license_key].presence }.compact,
      success_url: ENV["CHECKOUT_SUCCESS_URL"], cancel_url: ENV["CHECKOUT_CANCEL_URL"])
    render json: { url: session.url }
  end
end
