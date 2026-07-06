class Api::ProductsController < ActionController::API
  rescue_from ActiveRecord::RecordNotFound, with: -> { head :not_found }

  # Lets the storefront list a product's purchasable variants (Stripe prices).
  def variants
    product = Product.find_by!(slug: params[:slug])
    render json: { variants: product.variants.map(&:to_h) }
  end
end
