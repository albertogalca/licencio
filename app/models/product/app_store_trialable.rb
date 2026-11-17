# Trials sold through the App Store: a $0 one-time purchase starts one, trial_days long, and a
# paid one-time purchase is the sale. Apple's app transaction id, one per account per app, is
# the only thread from the first to the second. Purchases from before iOS 18.4 carry none, so
# their trials can never read as bought and the report counts them as unlinked.
module Product::AppStoreTrialable
  extend ActiveSupport::Concern

  def app_store_trial_report(now: Time.current)
    starts = trial_days ? app_store_charges.production.free.where(purchased_at: Product::TrialReport.window(now))
      .pluck(:purchased_at, :app_transaction_id) : []
    Product::TrialReport.from(app_store_trials(starts), now:, unlinked: starts.count { |_, id| id.nil? })
  end

  private
    # One query for every paid, unrevoked purchase by any of these buyers, not one per trial.
    def app_store_trials(starts)
      paid = app_store_charges.production.paid.unrevoked.where(app_transaction_id: starts.filter_map(&:last).uniq)
        .pluck(:app_transaction_id, :purchased_at).group_by(&:first).transform_values { _1.map(&:last) }

      starts.map do |started_at, app_transaction_id|
        bought_at = paid.fetch(app_transaction_id, []).select { _1 >= started_at }.min
        Product::Trial.new(started_at:, expires_at: started_at + trial_days.days, bought_at:)
      end
    end
end
