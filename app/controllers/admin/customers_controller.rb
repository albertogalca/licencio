class Admin::CustomersController < Admin::BaseController
  def index
    scope = Customer.order(:email)
    scope = scope.search(params[:q]) if params[:q].present?
    scope = scope.for_product(params[:product_id]) if params[:product_id].present?
    @customers = paginate(scope)
  end

  def show
    @customer = Customer.find(params[:id])
    @licenses = @customer.licenses.includes(:product, :activations)
  end
end
