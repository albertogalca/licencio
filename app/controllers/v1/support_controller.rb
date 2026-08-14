# The one place a human can ask "what did this address buy?" — because with no accounts and
# no dashboard, an unlock that goes wrong has no other way to be diagnosed. Not part of the
# public contract: shared-secret header, and never exposed to a client app.
class V1::SupportController < Api::PublicController
  # Returns every purchase row for any address it is asked about, so an unbudgeted guess at
  # the shared secret buys bulk customer PII. Named, or it would share a bucket with another
  # limiter. Low ceiling on purpose: this is one human on a support call, not a client app.
  rate_limit to: 10, within: 1.minute, name: "support-lookup", with: -> { head :too_many_requests }

  before_action :authenticate_support

  def lookup
    product = Product.find_by(slug: params[:product_slug]) or return render_api_error(:product_not_found)
    purchases = Purchase.for_email(product, params[:email]).order(:purchased_at)

    # Support's escape hatch: mail a code past the per-address budget, for the customer
    # who's already burned it on a typo'd address while on the phone.
    code_sent = params[:resend_code].present? &&
      ActiveModel::Type::Boolean.new.cast(params[:resend_code]) &&
      UnlockCodeJob.perform_now(product, params[:email].to_s).present?

    render json: { purchases: purchases.map { |p| summary(p) }, code_sent: }
  end

  private
    def authenticate_support
      provided = request.headers["X-Admin-Token"].to_s
      token = ENV["SUPPORT_ADMIN_TOKEN"].to_s
      unless token.present? && ActiveSupport::SecurityUtils.secure_compare(provided, token)
        Rails.logger.warn("[support] rejected lookup from #{request.remote_ip}")
        render_api_error(:unauthorized)
      end
    end

    def summary(purchase)
      purchase.slice(:id, :email, :tier, :purchased_at, :updates_until, :refunded_at,
        :platforms, :provider, :provider_order_id)
    end
end
