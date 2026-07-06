class Portal::SessionsController < Portal::BaseController
  skip_before_action :require_customer

  def create
    if customer = Customer.authenticate_token(params[:token])
      reset_session
      session[:customer_id] = customer.id
      customer.clear_auth_token! # single-use link
      redirect_to portal_root_path
    else
      redirect_to new_portal_recovery_path, alert: "That link is invalid or has expired. Request a new one."
    end
  end

  def destroy
    reset_session
    redirect_to new_portal_recovery_path, notice: "Signed out."
  end
end
