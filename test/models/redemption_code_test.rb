require "test_helper"

class RedemptionCodeTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @product = products(:picmal)
  end

  test "generated codes are 16 unambiguous characters, unique, and stored only as digests" do
    codes = RedemptionCode.generate!(product: @product, count: 500)

    assert_equal 500, codes.size
    assert_equal 500, codes.uniq.size
    assert codes.all? { it.match?(/\A[A-HJKMNP-Z2-9]{16}\z/) }, "no 0, O, 1, I or L"
    assert_equal 500, @product.redemption_codes.unredeemed.appsumo.count
    stored = @product.redemption_codes.pluck(:code_digest, :code_hint)
    assert_equal codes.map { RedemptionCode.digest(it) }.sort, stored.map(&:first).sort
    refute stored.flatten.intersect?(codes), "plaintext never reaches the database"
  end

  test "a collision with the pool is replaced, so the count is still exact" do
    taken = RedemptionCode.generate!(product: @product, count: 1).first
    fresh = "B" * 16
    draws = [ taken, fresh ].each
    RedemptionCode.stub :random_code, -> { draws.next } do
      assert_equal [ fresh ], RedemptionCode.generate!(product: @product, count: 1)
    end
  end

  test "import takes one code per line, skips duplicates and rejects bad lengths" do
    csv = "ALPHA123\nalpha123\nBETA-456\nXY\n\n#{"Z" * 201}\nGAMMA789\n"
    tally = RedemptionCode.import!(product: @product, io: StringIO.new(csv))

    assert_equal 3, tally[:imported]
    assert_equal 1, tally[:duplicates]
    assert_equal 3, tally[:invalid]
    assert RedemptionCode.find_by_code("beta456")
  end

  test "the first code makes a lifetime license with one Mac and emails the key" do
    code = generate

    assert_difference -> { License.count }, 1 do
      assert_enqueued_with(job: LicenseEmailJob) do
        @redeemed = RedemptionCode.redeem!(code, email: "new@example.com")
      end
    end

    license = @redeemed.license
    assert @redeemed.redeemed? && @redeemed.issued_license?
    assert_equal 1, license.max_activations
    assert_equal "lifetime", license.effective_update_policy
    assert_nil license.expires_at
    assert license.update_eligible?
    assert_equal "new@example.com", license.customer.email
    assert_equal :redemption_transactional_id, enqueued_email_template
  end

  test "codes stack on one key up to four, and the fifth is refused unused" do
    keys = 4.times.map { RedemptionCode.redeem!(generate, email: "stack@example.com").license }
    assert_equal 1, keys.map(&:license_key).uniq.size
    assert_equal 4, keys.last.reload.max_activations
    assert_equal :seats_added_transactional_id, enqueued_email_template

    fifth = generate
    assert_raises(RedemptionCode::StackLimitReached) { RedemptionCode.redeem!(fifth, email: "stack@example.com") }
    assert RedemptionCode.find_by_code(fifth).unredeemed?
    assert_equal 4, keys.last.reload.max_activations
  end

  test "a code adds a Mac to a license the email already bought, keeping its key and policy" do
    bought = @product.issue_license!(customer: customers(:alberto), quantity: 2, stripe_payment_id: "pi_bought")

    redeemed = RedemptionCode.redeem!(generate, email: "ALBERTO@example.com")

    assert_equal bought, redeemed.license
    assert_equal 3, bought.reload.max_activations
    assert_equal "time_limited", bought.effective_update_policy
    refute redeemed.issued_license?
  end

  test "a trial is not a license to stack on" do
    @product.licenses.create!(customer: customers(:alberto), status: "active", trial: true, max_activations: 1)

    redeemed = RedemptionCode.redeem!(generate, email: "alberto@example.com")

    assert redeemed.issued_license?
    refute redeemed.license.trial?
  end

  test "unknown, used and revoked codes all raise the same error" do
    used = generate
    RedemptionCode.redeem!(used, email: "a@example.com")
    revoked = generate
    RedemptionCode.find_by_code(revoked).revoke!

    [ "NOPE", used, revoked ].each do |code|
      assert_raises(RedemptionCode::Invalid) { RedemptionCode.redeem!(code, email: "b@example.com") }
    end
    assert_nil Customer.find_by(email: "b@example.com"), "a refused code writes nothing"
  end

  test "revoking a stacked code takes back one seat and signs out the newest device" do
    3.times { RedemptionCode.redeem!(generate, email: "rev@example.com") }
    code = RedemptionCode.redeemed.order(:redeemed_at).last
    license = code.license
    old_mac = license.activate!(hardware_id: "old")
    travel 1.minute
    license.activate!(hardware_id: "mid")
    travel 1.minute
    new_mac = license.activate!(hardware_id: "new")

    code.revoke!

    assert code.reload.revoked?
    assert_equal 2, license.reload.max_activations
    assert license.active?
    assert_nil old_mac.reload.deactivated_at
    assert new_mac.reload.deactivated_at, "the device past the cap stops working"
  end

  test "revoking the only code deactivates the license, and a second revoke is a no-op" do
    code = RedemptionCode.redeem!(generate, email: "solo@example.com")

    2.times { code.revoke! }

    assert_equal 0, code.license.reload.max_activations
    assert code.license.inactive?
    refute code.license.activatable?
  end

  test "a revoked code frees its place in the stack" do
    codes = 4.times.map { RedemptionCode.redeem!(generate, email: "free@example.com") }
    codes.last.revoke!

    assert_nothing_raised { RedemptionCode.redeem!(generate, email: "free@example.com") }
    assert_equal 4, codes.first.license.reload.max_activations
  end

  private
    def generate = RedemptionCode.generate!(product: @product, count: 1).first

    def enqueued_email_template
      enqueued_jobs.select { it["job_class"] == "LicenseEmailJob" }.last["arguments"].last["template"]["value"].to_sym
    end
end

# Real row locks need real commits, so this class runs outside the test transaction and
# cleans up after itself.
class RedemptionCodeRaceTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup { @product = products(:picmal) }

  EMAILS = %w[race0@example.com race1@example.com pair@example.com].freeze

  # By address, not through the codes: a failed redemption can leave a customer no code names.
  teardown do
    customers = Customer.where(email: EMAILS)
    licenses = License.where(customer: customers)
    RedemptionCode.where(product: @product).delete_all
    Payment.where(license: licenses).delete_all
    licenses.delete_all
    PortalToken.where(customer: customers).delete_all
    Notification.where(customer: customers).delete_all
    customers.delete_all
  end

  test "one code redeemed twice at once is redeemed exactly once" do
    code = RedemptionCode.generate!(product: @product, count: 1).first

    results = race(2) { |i| RedemptionCode.redeem!(code, email: "race#{i}@example.com") }

    assert_equal 1, results.count { it.is_a?(RedemptionCode) }
    assert_equal 1, results.count { it.is_a?(RedemptionCode::Invalid) }
    assert_equal 1, License.where(id: RedemptionCode.where(product: @product).select(:license_id)).count
  end

  test "two codes for one new email at once make one license with two Macs" do
    codes = RedemptionCode.generate!(product: @product, count: 2)

    results = race(2) { |i| RedemptionCode.redeem!(codes[i], email: "pair@example.com") }

    licenses = results.map(&:license).uniq
    assert_equal 1, licenses.size
    assert_equal 2, licenses.first.reload.max_activations
  end

  private
    def race(n)
      gate = Queue.new
      threads = n.times.map do |i|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            gate.pop
            yield i
          rescue RedemptionCode::Invalid => error
            error
          end
        end
      end
      n.times { gate << true }
      threads.map(&:value)
    end
end
