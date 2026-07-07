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
