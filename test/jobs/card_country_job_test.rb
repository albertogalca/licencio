require "test_helper"

class CardCountryJobTest < ActiveJob::TestCase
  setup do
    @product = products(:cozy)
    @payment = licenses(:cozy_active).payments.create!(stripe_payment_intent: "pi_card", kind: "purchase",
      regional_country: "PK")
  end

  test "stores where the card was issued next to the country the site vouched for" do
    @product.stub(:card_country, ->(intent) { "DE" if intent == "pi_card" }) do
      CardCountryJob.perform_now(@product, "pi_card")
    end
    assert_equal [ "PK", "DE" ], @payment.reload.values_at(:regional_country, :card_country)
  end

  test "a payment that was not a card, or is not ours, is left alone" do
    @product.stub(:card_country, nil) { CardCountryJob.perform_now(@product, "pi_card") }
    assert_nil @payment.reload.card_country
    @product.stub(:card_country, ->(*) { flunk "asked Stripe for an unknown payment" }) do
      CardCountryJob.perform_now(@product, "pi_unknown")
    end
  end
end
