# Trial to paid by the week each trial started, the last Product::TRIAL_COHORT_WEEKS weeks,
# newest first, for an outside dashboard. Mac trials by default; source=app_store reports the
# App Store's $0 trial purchases instead, plus how many of them could not be linked to a buyer.
class Api::Admin::TrialCohortsController < Api::Admin::BaseController
  def index
    product = Product.find_by!(slug: params[:product_slug])
    case params[:source]
    when nil
      render json: report_json(product, product.trial_report)
    when "app_store"
      report = product.app_store_trial_report
      render json: report_json(product, report).merge(unlinked: report.unlinked)
    else
      head :bad_request
    end
  end

  private
    def report_json(product, report)
      { product: product.slug, trial_days: product.trial_days, weeks: Product::TRIAL_COHORT_WEEKS,
        total: cohort_json(report.total), cohorts: report.weeks.map { cohort_json(_1) } }
    end

    def cohort_json(c)
      { week: c.week&.iso8601, started: c.started, running: c.running, bought: c.converted,
        median_days_to_buy: c.median_days&.round(1) }
    end
end
