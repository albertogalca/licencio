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

  test "a purchase adds the buyer to the mailing list unless newsletter is false" do
    product = products(:cozy)
    product.update!(loops_mailing_list_id: "list_cozy_news")
    lists = []
    Loops.stub(:upsert_contact, ->(mailing_lists:, **) { lists << mailing_lists }) do
      LoopsContactJob.perform_now(customers(:alberto), product, subscribed: true)
      LoopsContactJob.perform_now(customers(:alberto), product, subscribed: true, newsletter: false)
    end

    assert_equal [ { "list_cozy_news" => true }, nil ], lists
  end

  # Loops sends campaigns to every subscribed contact, so an App Store claimant who did not
  # consent must not become one. Driven through the real Loops calls, faking only HTTP.
  def loops_requests(responses, product: products(:cozy), **job_args)
    requests = []
    http = Object.new
    http.define_singleton_method(:request) { |req| requests << req; responses.shift }
    Net::HTTP.stub(:start, ->(*_a, **_k, &blk) { blk.call(http) }) do
      LoopsContactJob.perform_now(customers(:alberto), product, **job_args)
    end
    requests.map { |req| [ req.path, JSON.parse(req.body) ] }
  end

  def ok       = Net::HTTPOK.new("1.1", "200", "OK")
  def conflict = Net::HTTPConflict.new("1.1", "409", "Conflict")

  test "a claim without consent creates a new contact unsubscribed" do
    requests = loops_requests([ ok ], subscribed: true, newsletter: false)

    assert_equal [ "/api/v1/contacts/create" ], requests.map(&:first)
    assert_equal false, requests[0][1]["subscribed"]
    assert_not requests[0][1].key?("mailingLists")
  end

  test "a claim without consent leaves an existing contact's subscription alone" do
    requests = loops_requests([ conflict, ok ], subscribed: true, newsletter: false)

    assert_equal [ "/api/v1/contacts/create", "/api/v1/contacts/update" ], requests.map(&:first)
    update = requests[1][1]
    assert_not update.key?("subscribed"), "an existing subscriber stays subscribed"
    assert_not update.key?("mailingLists")
    assert_equal "lifetime", update["licenseTier"], "the license fields still sync"
  end

  test "a claim with consent, or a Stripe purchase, subscribes new and existing contacts" do
    product = products(:cozy)
    product.update!(loops_mailing_list_id: "list_cozy_news")
    [ { newsletter: true }, {} ].each do |args|
      requests = loops_requests([ conflict, ok ], product:, subscribed: true, **args)
      requests.each do |_path, body|
        assert_equal true, body["subscribed"]
        assert_equal({ "list_cozy_news" => true }, body["mailingLists"])
      end
    end
  end

  test "a refund unsubscribes an existing contact" do
    requests = loops_requests([ conflict, ok ], subscribed: false)
    assert_equal [ false, false ], requests.map { |_path, body| body["subscribed"] }
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
