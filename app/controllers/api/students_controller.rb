# Student discount, server side. The storefront runs the same domain check in JS, but
# that check only decides whether to make this call — it never sees the code. The code
# is mailed to the address that passed, so what buys the discount is access to the
# school inbox, not knowing which page to look at.
class Api::StudentsController < Api::PublicController
  # Sends email to a caller-supplied address — throttle per-IP against mail bombing.
  # Scoped to :create so preflights don't spend the budget.
  rate_limit to: 5, within: 1.minute, only: :create, with: -> { head :too_many_requests }

  # Called from a browser on picmal.app, and JSON isn't a CORS-safelisted content type,
  # so it preflights. Wildcard is honest here: public, rate limited, and no cookie or
  # API key rides along, so there's no credential for another origin to borrow.
  before_action :set_cors_headers

  def preflight
    head :no_content
  end

  def create
    product = Product.find_by!(slug: params[:product_slug])
    return render_api_error(:student_discount_unavailable) unless product.student_discount?
    return render_api_error(:not_academic_email) unless AcademicEmail.match?(params[:email])

    StudentDiscountJob.perform_later(product, params[:email].to_s.strip.downcase)
    render json: { sent: true }
  end

  private
    def set_cors_headers
      headers["Access-Control-Allow-Origin"]  = "*"
      headers["Access-Control-Allow-Headers"] = "Content-Type"
      headers["Access-Control-Max-Age"]       = "86400"
    end
end
