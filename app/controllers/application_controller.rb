class ApplicationController < ActionController::Base
  allow_browser versions: :modern

  stale_when_importmap_changes

  helper_method :branded_product

  private
    # The portal layout themes itself off this. Nothing is branded by default — admin, and
    # affiliate pages, which span every product. Portal::BaseController overrides it.
    def branded_product
      nil
    end
end
