class Portal::RecoveriesController < Portal::BaseController
  skip_before_action :require_customer

  # Sends email — throttle per-IP to blunt address enumeration and mail bombing.
  rate_limit to: 5, within: 1.minute, only: :create,
    with: -> { redirect_to new_portal_recovery_path(product: params[:product].presence), alert: "Too many requests. Try again in a minute." }

  def new
    @product_slug = params[:product]
    @product = find_product(@product_slug)
  end

  def create
    if product = find_product(params[:product])
      Customer.find_by(email: params[:email])&.send_portal_access_later(product:)
    end
    redirect_to new_portal_recovery_path(product: params[:product].presence), notice: "If that email has a license, a sign-in link is on its way."
  end

  private
    def find_product(value)
      Product.matching(value).first if value.present?
    end
end
