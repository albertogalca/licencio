class Api::CheckoutsController < Api::PublicController
  def create
    product = Product.find_by!(slug: params[:product_slug])
    session = product.create_checkout_session(
      price_id: params.require(:price_id),
      email: params[:email], renew_license_key: params[:renew_license_key])
    render json: { url: session.url }
  end
end
