class Admin::CustomersController < Admin::BaseController
  def index
    @customers = paginate(Customer.order(:email))
  end

  def show
    @customer = Customer.find(params[:id])
    @licenses = @customer.licenses.includes(:product, :activations)
  end
end
