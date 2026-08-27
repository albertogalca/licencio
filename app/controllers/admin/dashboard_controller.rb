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

    # Two grouped queries, not two per product: the Studio Model means the catalogue grows
    # and the overview shouldn't get slower every time it does.
    by_status = License.group(:product_id, :status).count
    devices   = Activation.active.joins(:license).group("licenses.product_id").count

    @products = Product.order(:name).map do |product|
      counts = by_status.select { |(id, _), _| id == product.id }
      {
        product:,
        licenses: counts.values.sum,
        active:   counts.fetch([ product.id, "active" ], 0),
        refunded: counts.fetch([ product.id, "refunded" ], 0),
        devices:  devices.fetch(product.id, 0)
      }
    end
  end
end
