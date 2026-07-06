class Api::RecoveriesController < Api::BaseController
  def create
    Customer.find_by(email: params[:email])&.send_portal_access_later(product: @product)
    head :ok
  end
end
