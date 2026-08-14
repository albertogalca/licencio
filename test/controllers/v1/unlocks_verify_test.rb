require "test_helper"

class V1::UnlocksVerifyTest < ActionDispatch::IntegrationTest
  setup do
    @product = products(:cozy)
    # The products fixture carries placeholder key material; sign with a real pair so the
    # token can actually be verified the way a client will verify it.
    @signing = Ed25519::SigningKey.generate
    @product.update!(unlock_transactional_id: "tmpl_cozy_unlock",
      eddsa_private_key: Base64.strict_encode64(@signing.to_bytes),
      eddsa_public_key: Base64.strict_encode64(@signing.verify_key.to_bytes))
    @purchase = purchases(:cozy_forever) # Ana.Perez+cozy@Gmail.com, forever
  end

  def verify(code:, email: "anaperez@gmail.com", device_id: "device-1", slug: @product.slug)
    post "/v1/unlock/verify",
      params: { product_slug: slug, email:, code:, device_id:, platform: "mac" }, as: :json
  end

  def issue(email: "anaperez@gmail.com")
    LoginCode.issue!(product: @product, email: Purchase.normalize_email(email))
  end

  test "the right code returns a permanent, verifiable entitlement token" do
    _record, code = issue
    verify(code:)

    assert_response :ok
    body = response.parsed_body
    assert_equal true, body["ok"]
    assert_equal "forever", body["tier"]
    assert_nil body["updates_until"]
    assert_equal %w[mac windows iphone], body["platforms"]

    header, claims, signature = body["token"].split(".")
    assert_equal({ "alg" => "EdDSA", "typ" => "JWT", "kid" => @product.eddsa_key_id },
      JSON.parse(Base64.urlsafe_decode64(header)))

    payload = JSON.parse(Base64.urlsafe_decode64(claims))
    assert_equal %w[v sub tier updates_until device iat].sort, payload.keys.sort
    assert_not_includes payload.keys, "exp"
    assert_equal 1, payload["v"]
    assert_equal @purchase.id, payload["sub"]
    assert_equal "device-1", payload["device"]
    assert_nil payload["updates_until"]

    assert @signing.verify_key.verify(Base64.urlsafe_decode64(signature), "#{header}.#{claims}"),
      "a client pinning eddsa_public_key must be able to verify this offline"
  end

  test "a standard purchase reports the date its updates run out" do
    @purchase.update!(tier: "standard", updates_until: Date.new(2027, 3, 1))
    _record, code = issue
    verify(code:)

    assert_equal "standard", response.parsed_body["tier"]
    assert_equal "2027-03-01", response.parsed_body["updates_until"]
    assert_equal "2027-03-01",
      JSON.parse(Base64.urlsafe_decode64(response.parsed_body["token"].split(".")[1]))["updates_until"]
  end

  # Case, dots and +tags all reach the same purchase — the buyer types what they remember.
  test "a differently spelled address still verifies" do
    _record, code = issue(email: "Ana.Perez+anything@Gmail.com")
    verify(code:, email: "ANAPEREZ@gmail.com")
    assert_response :ok
  end

  test "an expired code is gone, not merely wrong" do
    record, code = issue
    record.update!(expires_at: 1.second.ago)

    verify(code:)
    assert_response :gone
    assert_equal "code_expired", response.parsed_body["code"]
  end

  test "a code cannot be spent twice" do
    _record, code = issue
    verify(code:)
    assert_response :ok

    verify(code:)
    assert_response :unprocessable_entity
    assert_equal "code_invalid", response.parsed_body["code"]
  end

  test "six wrong codes burn the code, and the right digits no longer help" do
    _record, code = issue
    wrong = format("%06d", (code.to_i + 1) % 1_000_000)

    LoginCode::MAX_ATTEMPTS.times do
      verify(code: wrong)
      assert_response :unprocessable_entity
    end

    verify(code: wrong)
    assert_response :too_many_requests
    assert_equal "too_many_attempts", response.parsed_body["code"]

    verify(code:)
    assert_response :unprocessable_entity, "the burned code is gone for good"
  end

  test "a code with no code behind it is simply wrong" do
    verify(code: "000000")
    assert_response :unprocessable_entity
    assert_equal "code_invalid", response.parsed_body["code"]
  end

  # Owning the inbox is proved by now, so it's safe — and far more useful — to say which.
  test "a refunded purchase is refused as refunded" do
    email = purchases(:cozy_refunded).email
    _record, code = issue(email:)

    verify(code:, email:)
    assert_response :forbidden
    assert_equal "purchase_refunded", response.parsed_body["code"]
  end

  test "a valid code with nothing bought is a missing purchase, not a bad code" do
    _record, code = issue(email: "stranger@example.com")

    verify(code:, email: "stranger@example.com")
    assert_response :not_found
    assert_equal "purchase_not_found", response.parsed_body["code"]
  end

  test "an unknown product is not found" do
    _record, code = issue
    verify(code:, slug: "nope")
    assert_response :not_found
    assert_equal "product_not_found", response.parsed_body["code"]
  end

  # Unlimited devices, forever: the fifth machine is served exactly like the first, and
  # nothing anywhere counts them.
  test "five devices unlock the same purchase, and no table remembers any of them" do
    tokens = 5.times.map do |i|
      _record, code = issue
      verify(code:, device_id: "device-#{i}")
      assert_response :ok
      response.parsed_body["token"]
    end

    assert_equal 5, tokens.uniq.size
    tokens.each_with_index do |token, i|
      header, claims, signature = token.split(".")
      assert_equal "device-#{i}", JSON.parse(Base64.urlsafe_decode64(claims))["device"]
      assert @signing.verify_key.verify(Base64.urlsafe_decode64(signature), "#{header}.#{claims}")
    end

    device_columns = ActiveRecord::Base.connection.tables.flat_map do |table|
      ActiveRecord::Base.connection.columns(table).map { |c| "#{table}.#{c.name}" }
    end
    assert_empty device_columns.grep(/device_id/),
      "device_id must live in the token and nowhere else"
    assert_empty LoginCode.where(consumed_at: nil), "every code was spent exactly once"
  end

  test "the response allows the origin, success or failure" do
    _record, code = issue
    verify(code:)
    assert_equal "*", response.headers["Access-Control-Allow-Origin"]

    verify(code: "000000")
    assert_equal "*", response.headers["Access-Control-Allow-Origin"]
  end

  test "the preflight is answered" do
    process :options, "/v1/unlock/verify"
    assert_response :no_content
    assert_equal "*", response.headers["Access-Control-Allow-Origin"]
  end
end
