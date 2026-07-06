class Admin::DashboardController < Admin::BaseController
  def show
    since = 30.days.ago

    @active_licenses  = License.active.count
    @new_licenses     = License.where(created_at: since..).count
    # ponytail: no refunded_at column — updated_at proxies it since refund! only
    # touches status. Add a refunded_at column if this needs to be exact.
    @refunded         = License.refunded.where(updated_at: since..).count
    @customers        = Customer.count
    @active_devices   = Activation.active.count

    @products = Product.order(:name).map do |product|
      { product:, licenses: product.licenses.count, active: product.licenses.active.count }
    end
  end
end
