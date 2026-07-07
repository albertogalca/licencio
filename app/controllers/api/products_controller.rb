class Api::ProductsController < Api::PublicController
  # Unauthenticated and can reach Stripe (cache miss) — cap per-IP.
  rate_limit to: 30, within: 1.minute, with: -> { head :too_many_requests }

  # Lets the storefront list a product's purchasable variants (Stripe prices).
  def variants
    product = Product.find_by!(slug: params[:product_slug])
    render json: { variants: product.variants.map(&:to_h) }
  end
end
