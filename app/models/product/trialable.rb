# A product with trial_days lets one Mac run the full app for that long without a key. The trial
# is a real license keyed on the hardware_id, which is also the only thread from a trial to a
# sale: a trial has no email, and the purchase happens in the browser.
module Product::Trialable
  extend ActiveSupport::Concern

  TRIAL_COHORT_WEEKS = 8

  # One trial, as far as conversion goes. bought_at is the first paid, unrefunded activation on
  # the trial's Mac after the trial started. A buyer who activates the key on another Mac never
  # gets one, so reads as a miss.
  Trial = Data.define(:started_at, :expires_at, :bought_at) do
    def bought? = bought_at.present?
    def running?(now) = !bought? && expires_at > now
    def days_to_buy = ((bought_at - started_at) / 1.day if bought?)
  end

  TrialCohort = Data.define(:week, :started, :running, :converted, :median_days) do
    def self.from(trials, week:, now:)
      days = trials.filter_map(&:days_to_buy).sort
      median = (days[(days.size - 1) / 2] + days[days.size / 2]) / 2 if days.any?
      new(week:, started: trials.size, running: trials.count { _1.running?(now) },
        converted: days.size, median_days: median)
    end

    # Only trials that ended or bought are decided. A running trial is neither a sale nor a
    # miss yet, and counting it as a miss makes the newest week look like the worst one.
    def decided = started - running
    def rate = (converted.fdiv(decided) unless decided.zero?)
  end

  # The whole window as one cohort, plus each week of it, newest first.
  TrialReport = Data.define(:total, :weeks) do
    def empty? = weeks.empty?
  end

  included do
    scope :with_trial, -> { where.not(trial_days: nil) }
  end

  def trial_for(hardware_id:)
    return unless trial_days
    licenses.trials.joins(:activations).find_by(activations: { hardware_id: }) ||
      licenses.create!(status: "active", trial: true, max_activations: 1,
        expires_at: trial_days.days.from_now,
        licensed_version: (current_version if versioned?)).tap { |l| l.activate!(hardware_id:) }
  end

  def trial_report(now: Time.current)
    trials = trial_days ? trials_started_since((now - TRIAL_COHORT_WEEKS.weeks).beginning_of_week) : []
    weeks = trials.group_by { _1.started_at.to_date.beginning_of_week }.sort.reverse
      .map { |week, cohort| TrialCohort.from(cohort, week:, now:) }
    TrialReport.new(total: TrialCohort.from(trials, week: nil, now:), weeks:)
  end

  private
    # Two queries for the whole window, not one per trial: every trial's Macs, then every paid
    # activation on any of those Macs.
    def trials_started_since(since)
      rows = licenses.trials.joins(:activations).where(created_at: since..)
        .pluck("licenses.id", "licenses.created_at", "licenses.expires_at", "activations.hardware_id")
      paid = activations.where(hardware_id: rows.map(&:last).uniq, licenses: { trial: false })
        .where.not(licenses: { status: "refunded" })
        .pluck(:hardware_id, :activated_at).group_by(&:first).transform_values { _1.map(&:last) }

      rows.group_by(&:first).values.map do |macs|
        _, started_at, expires_at = macs.first
        bought_at = macs.flat_map { paid.fetch(_1.last, []) }.select { _1 >= started_at }.min
        Trial.new(started_at:, expires_at:, bought_at:)
      end
    end
end
