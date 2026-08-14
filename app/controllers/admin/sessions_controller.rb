class Admin::SessionsController < Admin::BaseController
  skip_before_action :require_admin

  rate_limit to: 10, within: 3.minutes, only: :create, name: "admin-login-ip",
    with: -> { redirect_to new_admin_session_path, alert: "Too many attempts. Try again in a few minutes." }

  # The IP budget above resets per source address, so guessing from many of them costs nothing.
  # This one budgets the account being guessed at instead, which is the thing worth protecting.
  rate_limit to: 10, within: 3.minutes, only: :create, name: "admin-login-account",
    by: -> { params[:email].to_s.downcase.strip },
    with: -> { redirect_to new_admin_session_path, alert: "Too many attempts. Try again in a few minutes." }

  def new
  end

  def create
    if admin = AdminUser.find_by(email: params[:email])&.authenticate(params[:password])
      reset_session
      session[:admin_user_id] = admin.id
      session[:admin_authenticated_at] = Time.current.to_i # ages the session out, see Admin::BaseController
      redirect_to admin_root_path
    else
      Rails.logger.warn("[admin] failed sign-in for #{params[:email].to_s.downcase.strip.inspect} from #{request.remote_ip}")
      redirect_to new_admin_session_path, alert: "Invalid email or password."
    end
  end

  def destroy
    reset_session
    redirect_to new_admin_session_path, notice: "Signed out."
  end
end
