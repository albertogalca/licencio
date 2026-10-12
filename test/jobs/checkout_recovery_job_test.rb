require "test_helper"

class CheckoutRecoveryJobTest < ActiveJob::TestCase
  setup do
    @product = products(:picmal)
    @product.update!(checkout_recovery_transactional_id: "tmpl_recovery")
  end

  test "sends the recovery link with the template's data" do
    sent = []
    Loops.stub(:send_transactional, ->(**kwargs) { sent << kwargs }) do
      recover("walked@example.com")
    end

    assert_equal 1, sent.size
    assert_equal "tmpl_recovery", sent.sole[:transactional_id]
    assert_equal "walked@example.com", sent.sole[:email]
    assert_equal({ recovery_url: "https://pay.example/r/abc", product_name: "Picmal",
                   sender_email: nil, pricing_url: "https://picmal.example/pricing" }, sent.sole[:data])
  end

  test "one address gets one recovery email per product, ever" do
    sends = 0
    Loops.stub(:send_transactional, ->(**) { sends += 1 }) do
      recover("walked@example.com")
      recover("walked@example.com", recovery_url: "https://pay.example/r/second-session")
    end

    assert_equal 1, sends
  end

  test "a buyer who already owns a license for the product gets nothing" do
    owner = customers(:nameless) # holds an expired picmal license
    assert @product.licenses.exists?(customer: owner)

    sends = 0
    Loops.stub(:send_transactional, ->(**) { sends += 1 }) do
      recover(owner.email.upcase)
    end

    assert_equal 0, sends
  end

  test "a recovery link that has already lapsed is not sent" do
    sends = 0
    Loops.stub(:send_transactional, ->(**) { sends += 1 }) do
      recover("walked@example.com", expires_at: 1.minute.ago)
    end

    assert_equal 0, sends
  end

  private
    def recover(email, recovery_url: "https://pay.example/r/abc", expires_at: 30.days.from_now)
      CheckoutRecoveryJob.perform_now(@product, email:, recovery_url:, expires_at:)
    end
end
