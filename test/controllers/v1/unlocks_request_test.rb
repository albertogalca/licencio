require "test_helper"

class V1::UnlocksRequestTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @product = products(:cozy)
    @product.update!(unlock_transactional_id: "tmpl_cozy_unlock")
    # The test env runs :null_store, which can't count — swap in something that can, so the
    # per-address budget is actually exercised.
    @default_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown { Rails.cache = @default_cache }

  def ask(email:, slug: @product.slug, platform: "mac")
    post "/v1/unlock/request", params: { product_slug: slug, email:, platform: }, as: :json
  end

  # The whole shape of this endpoint: it tells a stranger exactly what it tells a customer.
  test "an address that never bought anything gets the same ok, and no code" do
    assert_no_difference "LoginCode.count" do
      assert_no_enqueued_jobs do
        perform_enqueued_jobs { ask(email: "stranger@example.com") }
      end
    end

    assert_response :ok
    assert_equal({ "ok" => true }, response.parsed_body)
  end

  test "a buyer gets a code, whatever spelling they type" do
    assert_enqueued_with(job: UnlockCodeJob) { ask(email: "ana.perez@GMAIL.com") }
    assert_response :ok
    assert_equal({ "ok" => true }, response.parsed_body)

    assert_difference "LoginCode.count", 1 do
      Loops.stub :send_transactional, ->(**) { :sent } do
        perform_enqueued_jobs
      end
    end
    assert_equal "anaperez@gmail.com", LoginCode.order(:created_at).last.email
  end

  test "a refunded purchase gets no code, and still says ok" do
    assert_no_difference "LoginCode.count" do
      perform_enqueued_jobs { ask(email: purchases(:cozy_refunded).email) }
    end
    assert_response :ok
    assert_equal({ "ok" => true }, response.parsed_body)
  end

  # Three codes per address per fifteen minutes. The fourth request is answered exactly like
  # the first — a caller can't tell a throttled address from a stranger's.
  test "the fourth request in the window sends nothing and still says ok" do
    assert_enqueued_jobs 3, only: UnlockCodeJob do
      3.times { ask(email: "anaperez@gmail.com") }
    end

    assert_no_enqueued_jobs only: UnlockCodeJob do
      ask(email: "anaperez@gmail.com")
    end
    assert_response :ok
    assert_equal({ "ok" => true }, response.parsed_body)
  end

  test "the budget follows the inbox, not the spelling" do
    [ "anaperez@gmail.com", "ana.perez@gmail.com", "anaperez+one@gmail.com" ].each { |e| ask(email: e) }

    assert_no_enqueued_jobs only: UnlockCodeJob do
      ask(email: "A.n.a.Perez+two@Gmail.com")
    end
  end

  test "garbage is refused, and only garbage" do
    assert_no_enqueued_jobs do
      [ "", "nope", "no@domain", "two@@at.com", "spaces in@here.com" ].each do |email|
        ask(email:)
        assert_response :unprocessable_entity, email.inspect
        assert_equal "invalid_email", response.parsed_body["code"]
      end
    end
  end

  test "an unknown product is not found" do
    ask(email: "anaperez@gmail.com", slug: "nope")
    assert_response :not_found
    assert_equal "product_not_found", response.parsed_body["code"]
  end

  # Cozy for iPhone posts from capacitor://localhost, so WKWebView preflights first.
  test "the preflight is answered and allows the origin" do
    process :options, "/v1/unlock/request",
      headers: { "Origin" => "capacitor://localhost",
                 "Access-Control-Request-Method" => "POST",
                 "Access-Control-Request-Headers" => "content-type" }

    assert_response :no_content
    assert_equal "*", response.headers["Access-Control-Allow-Origin"]
    assert_includes response.headers["Access-Control-Allow-Headers"], "Content-Type"
  end

  test "the POST response allows the origin too" do
    ask(email: "anaperez@gmail.com")
    assert_equal "*", response.headers["Access-Control-Allow-Origin"]
  end

  test "the job mails the address on the purchase, not the one that was typed" do
    sent = nil
    Loops.stub :send_transactional, ->(**kwargs) { sent = kwargs } do
      UnlockCodeJob.perform_now(@product, "anaperez+whatever@gmail.com")
    end

    assert_equal purchases(:cozy_forever).email, sent[:email]
    assert_equal "tmpl_cozy_unlock", sent[:transactional_id]
    assert_match(/\A\d{6}\z/, sent[:data][:code])
    assert_equal @product.name, sent[:data][:product_name]
  end
end
