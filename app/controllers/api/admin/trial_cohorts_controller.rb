# Trial to paid by the week each trial started, the last Product::TRIAL_COHORT_WEEKS weeks,
# newest first, for an outside dashboard.
class Api::Admin::TrialCohortsController < Api::Admin::BaseController
  def index
    product = Product.find_by!(slug: params[:product_slug])
    report = product.trial_report
    render json: { product: product.slug, trial_days: product.trial_days, weeks: Product::TRIAL_COHORT_WEEKS,
      total: cohort_json(report.total), cohorts: report.weeks.map { cohort_json(_1) } }
  end

  private
    def cohort_json(c)
      { week: c.week&.iso8601, started: c.started, running: c.running, bought: c.converted,
        median_days_to_buy: c.median_days&.round(1) }
    end
end
