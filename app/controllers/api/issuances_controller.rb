# A bundle store (BundleHunt) calls this once per license it sells, with the buyer's details.
# Answers with the bare key in plain text, because the store shows the response body to the
# customer as-is. Authenticated by X-Api-Key, which is also what picks the product.
#
# That key is the product's issuance_api_key, never its api_key. The api_key ships inside every
# desktop build, so anyone can read it; accepting it here let anyone mint licenses.
class Api::IssuancesController < Api::PublicController
  before_action :authenticate_issuer

  rescue_from Product::CheckoutNotConfigured, with: -> { head :service_unavailable }
  rescue_from Product::InvalidSeats, with: -> { render_api_error(:invalid_seats) }

  def create
    if params[:email].to_s.strip.match?(URI::MailTo::EMAIL_REGEXP)
      render plain: issue.license_key
    else
      render_api_error(:invalid_email)
    end
  end

  private
    # A blank header must not match a product whose issuance key is nil.
    def authenticate_issuer
      key = request.headers["X-Api-Key"].presence
      @product = Product.find_by(issuance_api_key: key) if key
      render_api_error(:unauthorized) unless @product
    end

    # ponytail: no idempotency key. The store repeats one order number across every license in
    # a multi-license order, so it can't dedupe on that, and a retried call mints a spare key.
    # Add a bundle order id + line index column if a wasted key ever costs more than the column.
    def issue
      quantity = @product.issued_seats(params[:seats]) # before the upsert, so a refusal writes nothing
      customer = Customer.upsert!(email: params[:email].strip, name: params[:name].presence)
      @product.issue_license!(customer:, quantity:, stripe_payment_id: nil).tap do |license|
        license.deliver_later                        # portal link, so they can move devices later
        customer.subscribe_to_loops_later(product: @product)
      end
    end
end
