class Api::Admin::BaseController < ActionController::API
  before_action :authenticate_admin

  private
    def authenticate_admin
      provided = request.authorization.to_s.remove(/\ABearer /)
      key = ENV["ADMIN_API_KEY"].to_s
      unless key.present? && ActiveSupport::SecurityUtils.secure_compare(provided, key)
        head :unauthorized
      end
    end
end
