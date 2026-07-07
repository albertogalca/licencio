class Portal::RecoveriesController < Portal::BaseController
  skip_before_action :require_customer

  # Sends email — throttle per-IP to blunt address enumeration and mail bombing.
  rate_limit to: 5, within: 1.minute, only: :create,
    with: -> { redirect_to new_portal_recovery_path(product: params[:product].presence), alert: "Too many requests. Try again in a minute." }

  def new
    @product_slug = params[:product]
    @product = Product.find_by(slug: @product_slug) if @product_slug.present?
  end

  def create
    if product = find_product(params[:product])
      Customer.find_by(email: params[:email])&.send_portal_access_later(product:)
    end
    redirect_to new_portal_recovery_path(product: params[:product].presence), notice: "If that email has a license, a sign-in link is on its way."
  end

  private
    # Customers type whatever they remember — accept the slug or the display name, any case.
    def find_product(value)
      v = value.to_s.strip.downcase
      Product.where("lower(slug) = :v OR lower(name) = :v", v:).first if v.present?
    end
end
