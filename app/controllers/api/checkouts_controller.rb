class Api::CheckoutsController < ActionController::API
  rescue_from ActiveRecord::RecordNotFound, with: -> { head :not_found }

  def create
    product  = Product.find_by!(slug: params[:product_slug])
    quantity = [ params[:quantity].to_i, 1 ].max
    session  = Stripe::Checkout::Session.create(
      mode: "payment", customer_creation: "always",
      line_items: [ { price: Stripe::Product.retrieve(product.stripe_product_id).default_price,
                      quantity: } ],
      customer_email: params[:email].presence,
      metadata: { licencio_product_id: product.id, quantity:,
                  renew_license_key: params[:renew_license_key].presence }.compact,
      success_url: ENV["CHECKOUT_SUCCESS_URL"], cancel_url: ENV["CHECKOUT_CANCEL_URL"])
    render json: { url: session.url }
  end
end
