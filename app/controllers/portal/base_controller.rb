class Portal::BaseController < ApplicationController
  layout "portal"

  before_action :require_customer

  helper_method :current_customer, :current_product

  # The public keyed checkouts (renewals, upgrades) carry these from the storefront link,
  # through the form as hidden fields, into the Stripe session — the same way /api/checkout's do.
  ATTRIBUTION_PARAMS = %i[client_reference_id affonso_referral].freeze

  private
    # Anything long enough to make Stripe reject the whole session is dropped rather than
    # allowed to turn a junk query param into a failed checkout — losing the attribution on
    # one sale beats losing the sale.
    def attribution
      ATTRIBUTION_PARAMS.index_with { |key| params[key].presence&.then { |v| v if v.length <= 200 } }
    end

    def current_customer
      @current_customer ||= Customer.find_by(id: session[:customer_id])
    end

    # The portal is scoped to the product from the magic link — a Cozy session never shows Picmal.
    def current_product
      @current_product ||= Product.find_by(id: session[:portal_product_id])
    end

    # What the layout brands itself off. Recoveries sets @product from the ?product param
    # before anyone is signed in; everywhere else it's the product the magic link scoped us to.
    def branded_product
      @product || current_product
    end

    def require_customer
      unless current_customer && current_product
        redirect_to new_portal_recovery_path(product: current_product&.slug || params[:product])
      end
    end
end
