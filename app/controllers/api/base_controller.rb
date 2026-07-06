class Api::BaseController < ActionController::API
  before_action :authenticate_product

  rescue_from ActiveRecord::RecordNotFound, with: -> { head :not_found }
  rescue_from License::CapacityExceeded, with: -> { head :conflict }

  private
    def authenticate_product
      @product = Product.find_by(api_key: request.headers["X-Api-Key"])
      head :unauthorized unless @product
    end
end
