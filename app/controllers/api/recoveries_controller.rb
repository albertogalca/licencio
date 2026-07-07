class Api::RecoveriesController < Api::BaseController
  # Sends email — throttle per-IP against enumeration / mail bombing.
  rate_limit to: 5, within: 1.minute, with: -> { head :too_many_requests }

  def create
    Customer.find_by(email: params[:email])&.send_portal_access_later(product: @product)
    head :ok
  end
end
