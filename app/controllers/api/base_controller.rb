class Api::BaseController < Api::PublicController
  before_action :authenticate_product

  rescue_from License::CapacityExceeded, with: -> { render_api_error(:seat_limit_reached) }

  private
    def authenticate_product
      @product = Product.find_by(api_key: request.headers["X-Api-Key"])
      render_api_error(:unauthorized) unless @product
    end
end
