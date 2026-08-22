# A bundle store (BundleHunt) calls this once per license it sells, with the buyer's details.
# Answers with the bare key in plain text, because the store shows the response body to the
# customer as-is. Authenticated by X-Api-Key, which is also what picks the product.
class Api::IssuancesController < Api::BaseController
  rescue_from Product::CheckoutNotConfigured, with: -> { head :service_unavailable }

  def create
    if params[:email].to_s.strip.match?(URI::MailTo::EMAIL_REGEXP)
      render plain: issue.license_key
    else
      render_api_error(:invalid_email)
    end
  end

  private
    # ponytail: no idempotency key. The store repeats one order number across every license in
    # a multi-license order, so it can't dedupe on that, and a retried call mints a spare key.
    # Add a bundle order id + line index column if a wasted key ever costs more than the column.
    def issue
      customer = Customer.upsert!(email: params[:email].strip, name: params[:name].presence)
      @product.issue_license!(customer:, quantity: seats, stripe_payment_id: nil).tap do |license|
        license.deliver_later                        # portal link, so they can move devices later
        customer.subscribe_to_loops_later(product: @product)
      end
    end

    def seats
      (params[:seats].presence || @product.max_activations_default)&.to_i or
        raise Product::CheckoutNotConfigured, "#{@product.slug} has no max_activations_default"
    end
end
