class Api::CheckoutsController < ActionController::API
  rescue_from ActiveRecord::RecordNotFound, with: -> { head :not_found }

  def create
    product = Product.find_by!(slug: params[:product_slug])
    session = product.create_checkout_session(
      price_id: params.require(:price_id),
      email: params[:email], renew_license_key: params[:renew_license_key])
    render json: { url: session.url }
  end
end
