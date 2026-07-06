class Api::PublicController < ActionController::API
  rescue_from ActiveRecord::RecordNotFound, with: -> { head :not_found }
end
