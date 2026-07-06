class Api::RecoveriesController < Api::BaseController
  def create
    Customer.find_by(email: params[:email])&.deliver_magic_link_later(product: @product)
    head :ok
  end
end
