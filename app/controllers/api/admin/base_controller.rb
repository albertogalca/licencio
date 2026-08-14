class Api::Admin::BaseController < ActionController::API
  # Bulk license writes behind one environment-variable secret. The comparison is timing-safe;
  # this is the other half, a budget, so the secret cannot be ground down at wire speed.
  rate_limit to: 5, within: 1.minute, name: "api-admin", with: -> { head :too_many_requests }

  before_action :authenticate_admin

  private
    def authenticate_admin
      provided = request.authorization.to_s.remove(/\ABearer /)
      key = ENV["ADMIN_API_KEY"].to_s
      unless key.present? && ActiveSupport::SecurityUtils.secure_compare(provided, key)
        Rails.logger.warn("[api-admin] rejected request from #{request.remote_ip}")
        head :unauthorized
      end
    end
end
