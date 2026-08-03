require "test_helper"

class LoopsContactJobTest < ActiveJob::TestCase
  test "upserts the buyer as a Stripe-sourced contact with a split name" do
    customer = customers(:alberto) # name "Alberto"
    product  = products(:cozy)     # has a loops_api_key

    captured = nil
    Loops.stub(:upsert_contact, ->(**kwargs) { captured = kwargs }) do
      LoopsContactJob.perform_now(customer, product, subscribed: true)
    end

    assert_equal "Stripe", captured[:source]
    assert_equal true, captured[:subscribed]
    assert_equal customer.email, captured[:email]
    assert_equal "Alberto", captured[:first_name]
    assert_nil captured[:last_name]
  end

  test "passes subscribed: false through for unsubscribes" do
    captured = nil
    Loops.stub(:upsert_contact, ->(**kwargs) { captured = kwargs }) do
      LoopsContactJob.perform_now(customers(:alberto), products(:cozy), subscribed: false)
    end
    assert_equal false, captured[:subscribed]
  end

  # Loop C filters on these. A year of buyers without them is a year of renewal emails
  # that can't be targeted, which is why they ship before anything reads them.
  test "carries the license tier and update window as Loops properties" do
    customer = customers(:nameless)
    product  = products(:picmal) # time_limited/365
    license  = licenses(:picmal_expired)
    license.update!(status: "active", expires_at: Time.utc(2027, 3, 1, 12))

    captured = nil
    product.stub(:loops_api_key_or_default, "k") do
      Loops.stub(:upsert_contact, ->(**kwargs) { captured = kwargs }) do
        LoopsContactJob.perform_now(customer, product, subscribed: true)
      end
    end

    assert_equal "annual", captured[:properties][:licenseTier]
    assert_equal "2027-03-01T12:00:00Z", captured[:properties][:updatesUntil]
  end

  test "a lifetime license reports its tier and no update window" do
    captured = nil
    Loops.stub(:upsert_contact, ->(**kwargs) { captured = kwargs }) do
      LoopsContactJob.perform_now(customers(:alberto), products(:cozy), subscribed: true)
    end

    assert_equal "lifetime", captured[:properties][:licenseTier] # cozy fixture is lifetime
    assert_nil captured[:properties][:updatesUntil], "nothing to renew, so no date"
  end

  # Someone who bought annually and later bought lifetime is a lifetime customer, and must
  # not keep receiving renewal nags for the window they outgrew.
  test "a lifetime license outranks a dated one" do
    product = products(:picmal)
    lifetime = product.licenses.create!(customer: customers(:nameless),
      status: "active", max_activations: 1, update_policy: "lifetime")
    licenses(:picmal_expired).update!(status: "active", expires_at: 1.year.from_now)

    captured = nil
    product.stub(:loops_api_key_or_default, "k") do
      Loops.stub(:upsert_contact, ->(**kwargs) { captured = kwargs }) do
        LoopsContactJob.perform_now(customers(:nameless), product, subscribed: true)
      end
    end

    assert_equal "lifetime", captured[:properties][:licenseTier]
    assert_nil captured[:properties][:updatesUntil]
    assert lifetime.persisted?
  end

  test "does nothing when the product has no Loops API key" do
    product = products(:cozy)
    called = false
    product.stub(:loops_api_key_or_default, nil) do
      Loops.stub(:upsert_contact, ->(**) { called = true }) do
        LoopsContactJob.perform_now(customers(:alberto), product, subscribed: true)
      end
    end
    assert_not called
  end
end
