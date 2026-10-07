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

  # hardware_id is a random id the app keeps in a plain file, so on its own it is one trial per
  # install, and a new install is a new trial. machine_id closes that: a salted SHA-256 of the
  # OS machine id, sent only with this keyless request. Anything but 64 hex characters counts as
  # absent, so older clients keep the hardware_id behaviour.
  MACHINE_ID_FORMAT = /\A\h{64}\z/

  # New trials one IP may start per product per UTC day. Generous on purpose: an office, a
  # school or a mobile carrier puts many real people behind one address, and five new Macs in
  # a day from one of them is already unusual. It only slows a farm down; machine_id does the
  # real work. A trial that already exists is never refused by it. The address is
  # Current.ip_address; without one (console, jobs) there is no cap.
  TRIAL_STARTS_PER_IP_PER_DAY = 5

  def trial_for(hardware_id:, machine_id: nil)
    return unless trial_days
    machine_id = machine_id.to_s.downcase
    machine_id = nil unless machine_id.match?(MACHINE_ID_FORMAT)

    trial_on_install(hardware_id:, machine_id:) ||
      trial_on_machine(hardware_id:, machine_id:) ||
      start_trial(hardware_id:, machine_id:)
  end

  def trial_report(now: Time.current)
    trials = trial_days ? trials_started_since((now - TRIAL_COHORT_WEEKS.weeks).beginning_of_week) : []
    weeks = trials.group_by { _1.started_at.to_date.beginning_of_week }.sort.reverse
      .map { |week, cohort| TrialCohort.from(cohort, week:, now:) }
    TrialReport.new(total: TrialCohort.from(trials, week: nil, now:), weeks:)
  end

  private
    # A trial from before machine_id adopts it the first time its install sends one, unless the
    # machine already has a trial of its own: that one stays the machine's.
    def trial_on_install(hardware_id:, machine_id:)
      trial = licenses.trials.joins(:activations).find_by(activations: { hardware_id: })
      if trial && machine_id && trial.machine_id.nil? && !licenses.trials.exists?(machine_id:)
        trial.adopt_machine(machine_id)
      end
      trial
    end

    def trial_on_machine(hardware_id:, machine_id:)
      return unless machine_id
      licenses.trials.find_by(machine_id:)&.tap { _1.join_trial!(hardware_id:) }
    end

    def start_trial(hardware_id:, machine_id:)
      ip = Current.ip_address
      return if ip && trial_starts_from(ip) >= TRIAL_STARTS_PER_IP_PER_DAY
      trial = licenses.create!(status: "active", trial: true, max_activations: 1,
        expires_at: trial_days.days.from_now, machine_id:,
        licensed_version: (current_version if versioned?)).tap { |l| l.activate!(hardware_id:) }
      count_trial_start(ip) if ip
      trial
    rescue ActiveRecord::RecordNotUnique
      # Another request from this machine created its trial a moment ago.
      trial_on_machine(hardware_id:, machine_id:)
    end

    # Cache, not a column: the address is only needed for a day, so it is never stored with
    # the licence. Hashed so the cache holds no address either.
    def trial_start_key(ip)
      "trial-starts:#{id}:#{Time.current.utc.to_date.iso8601}:#{Digest::SHA256.hexdigest(ip.to_s)}"
    end

    def trial_starts_from(ip) = Rails.cache.read(trial_start_key(ip)).to_i

    def count_trial_start(ip) = Rails.cache.increment(trial_start_key(ip), 1, expires_in: 2.days)

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
