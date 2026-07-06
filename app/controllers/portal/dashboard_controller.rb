class Portal::DashboardController < Portal::BaseController
  def show
    @licenses = current_product.licenses.where(customer: current_customer).includes(:activations)
  end
end
