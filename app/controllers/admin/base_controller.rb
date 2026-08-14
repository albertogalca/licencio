class Admin::BaseController < ApplicationController
  layout "admin"

  before_action :require_admin

  helper_method :current_admin

  private
    def current_admin
      @current_admin ||= AdminUser.find_by(id: session[:admin_user_id])
    end

    # An admin cookie has nothing to expire server-side, so a lifted one stays good forever
    # against the surface that holds every Stripe secret and every customer's PII. One working
    # day: long enough not to nag, short enough that a stolen session dies overnight.
    ADMIN_SESSION_MAX_AGE = 12.hours

    def require_admin
      reset_session if session[:admin_authenticated_at].to_i < ADMIN_SESSION_MAX_AGE.ago.to_i
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
