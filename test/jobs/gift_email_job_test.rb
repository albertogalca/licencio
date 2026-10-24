require "test_helper"

class GiftEmailJobTest < ActiveJob::TestCase
  setup do
    @product = products(:cozy)
    @product.update!(gift_card_url: "https://cozy.example/gift/card/", gift_transactional_id: "tmpl_gift")
    @gift = @product.gifts.create!(stripe_session_id: "cs_gift", stripe_payment_intent: "pi_gift",
      buyer_email: "giver@example.com", tier: "forever", to_name: "Ana")
  end

  test "mails the buyer the card link once" do
    sent = []
    Loops.stub(:send_transactional, ->(**args) { sent << args }) do
      GiftEmailJob.perform_now(@gift)
      GiftEmailJob.perform_now(@gift)
    end

    assert_equal 1, sent.size
    assert_equal "giver@example.com", sent.first[:email]
    assert_equal "tmpl_gift", sent.first[:transactional_id]
    assert_equal "https://cozy.example/gift/card/##{@gift.display_code}", sent.first[:data][:card_url]
    assert_equal "Ana", sent.first[:data][:to_name]
  end

  test "sends nothing without a template" do
    @product.update!(gift_transactional_id: nil)
    Loops.stub(:send_transactional, ->(**) { flunk "sent" }) { GiftEmailJob.perform_now(@gift) }
    assert_nil @gift.reload.emailed_at
  end
end
