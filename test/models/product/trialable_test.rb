require "test_helper"

# A trial is keyed on hardware_id, which the desktop app stores as a random id in a plain file.
# Writing a new one used to buy a new trial. machine_id is a salted hash of the OS machine id,
# sent only with the keyless trial request, and it holds one trial per machine.
class Product::TrialableTest < ActiveSupport::TestCase
  MACHINE = "a" * 64
  OTHER_MACHINE = "b" * 64

  setup do
    @product = products(:picmal)
    @product.update!(trial_days: 7)
  end

  test "a new install on a known machine gets the first trial's window, not a fresh one" do
    first = travel_to(3.days.ago) { @product.trial_for(hardware_id: "HW-1", machine_id: MACHINE) }

    second = assert_no_difference("License.count") do
      @product.trial_for(hardware_id: "HW-2", machine_id: MACHINE)
    end

    assert_equal first, second
    assert_equal first.expires_at, second.expires_at
    assert_equal %w[HW-1 HW-2], second.activations.active.order(:activated_at).pluck(:hardware_id)
  end

  test "the controller's own activate! for the second install finds its seat already there" do
    @product.trial_for(hardware_id: "HW-1", machine_id: MACHINE)
    trial = @product.trial_for(hardware_id: "HW-2", machine_id: MACHINE)

    assert_nothing_raised { trial.activate!(hardware_id: "HW-2") }
    assert_nothing_raised { trial.activate!(hardware_id: "HW-1") }
  end

  test "asking again from the same install neither adds a seat nor a trial" do
    trial = @product.trial_for(hardware_id: "HW-1", machine_id: MACHINE)

    assert_no_difference [ "License.count", "Activation.count" ] do
      assert_equal trial, @product.trial_for(hardware_id: "HW-1", machine_id: MACHINE)
    end
    assert_equal 1, trial.reload.max_activations
  end

  test "a new install on a machine whose trial ran out gets that expired trial and no seat" do
    first = travel_to(8.days.ago) { @product.trial_for(hardware_id: "HW-1", machine_id: MACHINE) }

    assert_no_difference [ "License.count", "Activation.count" ] do
      assert_equal first, @product.trial_for(hardware_id: "HW-2", machine_id: MACHINE)
    end
    assert_predicate first.reload, :expired?
  end

  test "another machine gets its own trial" do
    first = @product.trial_for(hardware_id: "HW-1", machine_id: MACHINE)
    other = @product.trial_for(hardware_id: "HW-2", machine_id: OTHER_MACHINE)

    assert_not_equal first, other
  end

  test "the same machine on another product is another trial" do
    other_product = products(:cozy)
    other_product.update!(trial_days: 7)

    first = @product.trial_for(hardware_id: "HW-1", machine_id: MACHINE)
    other = other_product.trial_for(hardware_id: "HW-2", machine_id: MACHINE)

    assert_not_equal first, other
  end

  test "an older client without machine_id keeps the hardware_id behaviour" do
    first = @product.trial_for(hardware_id: "HW-1")
    second = @product.trial_for(hardware_id: "HW-2")

    assert_not_equal first, second
    assert_nil second.machine_id
  end

  test "a malformed machine_id counts as none, so it cannot be used to collide with real ones" do
    trial = @product.trial_for(hardware_id: "HW-1", machine_id: "raw-ioplatform-uuid")
    assert_nil trial.machine_id
  end

  test "a trial from before machine_id adopts it on the next request from that install" do
    old = @product.trial_for(hardware_id: "HW-1")
    @product.trial_for(hardware_id: "HW-1", machine_id: MACHINE)
    assert_equal MACHINE, old.reload.machine_id

    assert_equal old, @product.trial_for(hardware_id: "HW-2", machine_id: MACHINE)
  end

  test "an install cannot move a machine's trial onto its own" do
    taken = @product.trial_for(hardware_id: "HW-1", machine_id: MACHINE)
    old = @product.trial_for(hardware_id: "HW-OLD")

    assert_equal old, @product.trial_for(hardware_id: "HW-OLD", machine_id: MACHINE)
    assert_nil old.reload.machine_id
    assert_equal MACHINE, taken.reload.machine_id
  end

  test "one IP starts at most TRIAL_STARTS_PER_IP_PER_DAY new trials a day" do
    with_cache do
      cap = Product::Trialable::TRIAL_STARTS_PER_IP_PER_DAY
      from("203.0.113.7") do
        cap.times { |i| assert @product.trial_for(hardware_id: "HW-#{i}") }

        assert_no_difference("License.count") do
          assert_nil @product.trial_for(hardware_id: "HW-LAST")
        end
      end
      from("198.51.100.1") { assert @product.trial_for(hardware_id: "HW-ELSEWHERE") }

      travel 1.day do
        from("203.0.113.7") { assert @product.trial_for(hardware_id: "HW-TOMORROW") }
      end
    end
  end

  test "the IP cap never refuses a trial that already exists" do
    with_cache do
      from("203.0.113.7") do
        trial = @product.trial_for(hardware_id: "HW-0", machine_id: MACHINE)
        Product::Trialable::TRIAL_STARTS_PER_IP_PER_DAY.times do |i|
          @product.trial_for(hardware_id: "HW-X#{i}")
        end

        assert_equal trial, @product.trial_for(hardware_id: "HW-0")
        assert_equal trial, @product.trial_for(hardware_id: "HW-NEW", machine_id: MACHINE)
      end
    end
  end

  test "without a request address there is no cap" do
    with_cache do
      (Product::Trialable::TRIAL_STARTS_PER_IP_PER_DAY + 1).times do |i|
        assert @product.trial_for(hardware_id: "HW-#{i}")
      end
    end
  end

  private
    # The test env uses a null cache store, which would make the per-IP counter forget.
    def with_cache(&)
      Rails.stub(:cache, ActiveSupport::Cache::MemoryStore.new, &)
    end

    def from(ip, &) = Current.set(ip_address: ip, &)
end
