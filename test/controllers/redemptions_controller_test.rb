require "test_helper"

class RedemptionsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup { @product = products(:picmal) }

  test "the form is branded by ?product" do
    get redeem_path(product: "picmal")
    assert_response :ok
    assert_select "h1", /Redeem your Picmal code/
    assert_select "input[name=email]"
    assert_select "input[name=code]"
  end

  test "a valid code shows the key and the steps, and emails it" do
    assert_enqueued_with(job: LicenseEmailJob) do
      redeem(code: generate, email: " New@Example.com ")
    end

    assert_response :ok
    license = Customer.find_by!(email: "new@example.com").licenses.sole
    assert_select "input[value=?]", license.license_key
    assert_select "li", /Register license/
    assert_select "p", /1 Mac\./
  end

  test "an invalid code and a used code get the same answer" do
    used = generate
    redeem(code: used, email: "first@example.com")

    redeem(code: "NOTACODE", email: "a@example.com")
    invalid_body = [ response.status, flash[:alert] ]
    redeem(code: used, email: "a@example.com")

    assert_response :unprocessable_entity
    assert_equal invalid_body, [ response.status, flash[:alert] ]
    assert_match(/isn't valid, or it was already used/, flash[:alert])
    assert_select "input[name=email][value=?]", "a@example.com"
  end

  test "stacking says the new Mac count, and the fifth code is refused with its own message" do
    4.times { redeem(code: generate, email: "stack@example.com") }
    assert_select "h1", /One more Mac added/
    assert_select "p", /4 Macs\./

    redeem(code: generate, email: "stack@example.com")
    assert_response :unprocessable_entity
    assert_match(/already has 4 codes.*not used/, flash[:alert])
  end

  test "a malformed email is refused before the code is touched" do
    code = generate
    redeem(code:, email: "nope")
    assert_response :unprocessable_entity
    assert RedemptionCode.find_by_code(code).unredeemed?
  end

  # The test cache is a NullStore that never counts, so this one counts by key, which tells
  # the IP limiter's bucket from the email limiter's.
  test "redemptions are limited per IP and per email" do
    counts = Hash.new(0)
    Rails.cache.stub :increment, ->(key, amount = 1, **) { counts[key] += amount } do
      10.times { |i| redeem(code: "BAD#{i}", email: "same@example.com") }
      assert_response :unprocessable_entity
      redeem(code: generate, email: "same@example.com")
      assert_response :too_many_requests

      9.times { |i| redeem(code: "BAD#{i}", email: "other#{i}@example.com") }
      assert_response :unprocessable_entity, "the 20th request from this IP is still let through"
      redeem(code: "BAD", email: "fresh@example.com")
      assert_response :too_many_requests, "the IP budget is spent across addresses too"
    end
    assert counts.keys.any? { it.include?("redeem-email") }
    assert counts.keys.any? { it.include?("redeem-ip") }
  end

  private
    def generate = RedemptionCode.generate!(product: @product, count: 1).first

    def redeem(code:, email:)
      post redeem_path, params: { code:, email:, product: "picmal" }
    end
end
