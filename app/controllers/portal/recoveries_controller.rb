class Portal::RecoveriesController < Portal::BaseController
  skip_before_action :require_customer

  def new
    @product_slug = params[:product]
  end

  def create
    if product = Product.find_by(slug: params[:product])
      Customer.find_by(email: params[:email])&.deliver_magic_link_later(product:)
    end
    redirect_to new_portal_recovery_path, notice: "If that email has a license, a sign-in link is on its way."
  end
end
