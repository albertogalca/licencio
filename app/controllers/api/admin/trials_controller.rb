class Api::Admin::TrialsController < Api::Admin::BaseController
  def index
    product = Product.find_by!(slug: params[:product_slug])
    from, to = Date.iso8601(params[:from].to_s), Date.iso8601(params[:to].to_s)
    return render_bad_dates if to < from

    window = product.trial_window(from:, to:)
    render json: { product: product.slug, trial_days: product.trial_days,
      from: from.iso8601, to: to.iso8601, **window.to_h.except(:from, :to) }
  rescue Date::Error
    render_bad_dates
  end

  private
    def render_bad_dates
      render json: { error: "from and to must be YYYY-MM-DD dates, with to on or after from.",
        code: :invalid_dates }, status: :bad_request
    end
end
