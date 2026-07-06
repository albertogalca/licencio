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

    # Slices a scope into a page and exposes @page/@total_pages/@total_count for the
    # shared admin/pagination partial. ponytail: limit/offset beats a pagination gem here.
    def paginate(scope, per: 50)
      @page = [ params[:page].to_i, 1 ].max
      @total_count = scope.count
      @total_pages = [ (@total_count / per.to_f).ceil, 1 ].max
      scope.limit(per).offset((@page - 1) * per)
    end
end
