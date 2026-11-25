require "test_helper"

class GoogleAnalyticsTest < ActiveSupport::TestCase
  Visitor = GoogleAnalytics::Visitor

  test "a reference is a visitor only when it is a client id and a session id" do
    assert_equal [ "123.456", "789" ], Visitor.parse("123.456.789").deconstruct_keys(nil).values
    [ nil, "", "ph_abc", "visitor_1", "123.456", "1.2.3.4", "1.2.x", "1.2.3\n4", " 1.2.3" ].each do |reference|
      assert_nil Visitor.parse(reference), reference.inspect
    end
  end

  test "a value is in major units, whatever the currency counts in" do
    assert_equal 29.99, GoogleAnalytics.value(2999, "usd")
    assert_equal 4900, GoogleAnalytics.value(4900, "jpy")
  end

  test "sends the sale under the visit, and nothing about the buyer" do
    body = JSON.parse(deliver(Net::HTTPNoContent.new("1.1", "204", "No Content")).body)

    assert_equal "123.456", body["client_id"]
    assert_equal({ "ad_user_data" => "DENIED", "ad_personalization" => "DENIED" }, body["consent"])
    event = body["events"].sole
    assert_equal "purchase", event["name"]
    assert_equal({ "session_id" => "789", "engagement_time_msec" => 1, "transaction_id" => "cs_1",
      "value" => 29.0, "currency" => "USD", "items" => [ { "item_id" => "price_1", "quantity" => 1 } ] }, event["params"])
    assert_equal %w[client_id consent events], body.keys.sort
  end

  test "a rejection fails loudly, without the secret in the message" do
    error = assert_raises(RuntimeError) { deliver(Net::HTTPServiceUnavailable.new("1.1", "503", "Unavailable")) }
    assert_match "503", error.message
    assert_no_match "s3cret", error.message
  end

  private
    def deliver(response)
      sent = nil
      http = Object.new
      http.define_singleton_method(:request) { |req| sent = req; response }
      Net::HTTP.stub(:start, ->(*_a, **_k, &blk) { blk.call(http) }) do
        GoogleAnalytics.send_purchase(measurement_id: "G-TEST", api_secret: "s3cret",
          visitor: Visitor.parse("123.456.789"), transaction_id: "cs_1", amount: 2900, currency: "usd", item: "price_1")
      end
      assert_equal "measurement_id=G-TEST&api_secret=s3cret", sent.uri.query
      sent
    end
end
