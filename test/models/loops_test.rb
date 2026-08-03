require "test_helper"

class LoopsTest < ActiveSupport::TestCase
  # Records requests and returns queued responses in order, standing in for Net::HTTP.
  class FakeHTTP
    attr_reader :requests
    def initialize(responses)
      @responses = responses
      @requests = []
    end

    def request(req)
      @requests << req
      @responses.shift
    end
  end

  def stubbing(fake, &block)
    Net::HTTP.stub(:start, ->(*_a, **_k, &blk) { blk.call(fake) }, &block)
  end

  test "custom properties ride along as top-level fields, blanks dropped" do
    fake = FakeHTTP.new([ Net::HTTPOK.new("1.1", "200", "OK") ])
    stubbing(fake) do
      Loops.upsert_contact(api_key: "k", email: "a@b.com", source: "Stripe",
        properties: { licenseTier: "annual", updatesUntil: "2027-03-01T12:00:00Z",
                      somethingBlank: nil })
    end

    body = JSON.parse(fake.requests[0].body)
    assert_equal "annual", body["licenseTier"]
    assert_equal "2027-03-01T12:00:00Z", body["updatesUntil"]
    assert_not body.key?("somethingBlank"), "a nil property is omitted, not sent as null"
  end

  test "upsert_contact creates, then updates with the same payload on 409" do
    fake = FakeHTTP.new([
      Net::HTTPConflict.new("1.1", "409", "Conflict"),
      Net::HTTPOK.new("1.1", "200", "OK")
    ])
    stubbing(fake) do
      Loops.upsert_contact(api_key: "k", email: "a@b.com", source: "Stripe",
        first_name: "Ada", last_name: "Byron")
    end

    assert_equal 2, fake.requests.size
    assert_equal "/api/v1/contacts/create", fake.requests[0].path
    assert_equal "/api/v1/contacts/update", fake.requests[1].path
    body = JSON.parse(fake.requests[0].body)
    assert_equal "Stripe", body["source"]
    assert_equal true, body["subscribed"]
    assert_equal "Ada", body["firstName"]
    assert_equal JSON.parse(fake.requests[1].body), body, "update reuses the create payload"
  end

  test "upsert_contact stops after a successful create" do
    fake = FakeHTTP.new([ Net::HTTPOK.new("1.1", "200", "OK") ])
    stubbing(fake) do
      Loops.upsert_contact(api_key: "k", email: "a@b.com", source: "Stripe", subscribed: false)
    end

    assert_equal 1, fake.requests.size
    assert_equal false, JSON.parse(fake.requests[0].body)["subscribed"]
  end

  test "upsert_contact raises on a non-409 error so the job retries" do
    bad = Net::HTTPBadRequest.new("1.1", "400", "Bad Request")
    bad.stub(:body, "nope") do
      fake = FakeHTTP.new([ bad ])
      assert_raises(RuntimeError) do
        stubbing(fake) do
          Loops.upsert_contact(api_key: "k", email: "a@b.com", source: "Stripe")
        end
      end
    end
  end
end
