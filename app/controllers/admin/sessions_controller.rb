class Admin::SessionsController < Admin::BaseController
  skip_before_action :require_admin

  def new
  end

  def create
    if admin = AdminUser.find_by(email: params[:email])&.authenticate(params[:password])
      reset_session
      session[:admin_user_id] = admin.id
      redirect_to admin_root_path
    else
      redirect_to new_admin_session_path, alert: "Invalid email or password."
    end
  end

  def destroy
    reset_session
    redirect_to new_admin_session_path, notice: "Signed out."
  end
end
