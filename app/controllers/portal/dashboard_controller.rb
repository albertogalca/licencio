class Portal::DashboardController < Portal::BaseController
  def show
    @licenses_by_product = current_customer.licenses.includes(:product, :activations).group_by(&:product)
  end
end
