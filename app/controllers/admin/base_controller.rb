class Admin::BaseController < ApplicationController
  layout "admin"

  before_action :require_admin

  helper_method :current_admin

  private
    def current_admin
      @current_admin ||= AdminUser.find_by(id: session[:admin_user_id])
    end

    def require_admin
      redirect_to new_admin_session_path unless current_admin
    end
end
