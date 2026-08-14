require "test_helper"

class LoginCodeTest < ActiveSupport::TestCase
  setup do
    @product = products(:cozy)
    @email = "anaperez@gmail.com"
  end

  test "issue! returns six digits and stores only their hash" do
    record, code = LoginCode.issue!(product: @product, email: @email)

    assert_match(/\A\d{6}\z/, code)
    assert_equal LoginCode.hash_code(record.id, code), record.code_hash
    # No column anywhere holds the digits — the only copy left is in the customer's inbox.
    assert_not_includes record.reload.attributes.values.map(&:to_s), code
  end

  # The same six digits under a different row id hash differently, so a stolen hash from one
  # request can't be replayed against another.
  test "the hash is bound to the row it belongs to" do
    assert_not_equal LoginCode.hash_code(SecureRandom.uuid, "123456"),
      LoginCode.hash_code(SecureRandom.uuid, "123456")
  end

  test "issue! retires every earlier live code for the address" do
    old, old_code = LoginCode.issue!(product: @product, email: @email)
    LoginCode.issue!(product: @product, email: @email)

    assert old.reload.consumed_at, "the previous code must not still be spendable"
    assert_equal :code_invalid, old.verify!(old_code)
  end

  test "issue! leaves another address's code alone" do
    other, = LoginCode.issue!(product: @product, email: "someone.else@example.com")
    LoginCode.issue!(product: @product, email: @email)
    assert_nil other.reload.consumed_at
  end

  test "the right code verifies once and is then spent" do
    record, code = LoginCode.issue!(product: @product, email: @email)

    assert_equal :ok, record.verify!(code)
    assert record.consumed_at
    assert_equal :code_invalid, record.verify!(code), "replay must be refused"
  end

  test "an expired code is refused even when the digits are right" do
    record, code = LoginCode.issue!(product: @product, email: @email)
    record.update!(expires_at: 1.second.ago)

    assert_equal :code_expired, record.verify!(code)
  end

  test "expires ten minutes out" do
    record, = LoginCode.issue!(product: @product, email: @email)
    assert_in_delta LoginCode::TTL.from_now.to_i, record.expires_at.to_i, 5
  end

  # Five tries is what makes six digits safe; the sixth burns the code.
  test "five wrong tries are allowed, the sixth burns the code" do
    record, code = LoginCode.issue!(product: @product, email: @email)

    LoginCode::MAX_ATTEMPTS.times do |i|
      assert_equal :code_invalid, record.verify!(wrong(code)), "try #{i + 1}"
      assert_nil record.consumed_at
    end

    assert_equal :too_many_attempts, record.verify!(wrong(code))
    assert record.consumed_at, "burned"
  end

  test "a burned code refuses the correct digits" do
    record, code = LoginCode.issue!(product: @product, email: @email)
    (LoginCode::MAX_ATTEMPTS + 1).times { record.verify!(wrong(code)) }

    assert_equal :too_many_attempts, record.verify!(code)
  end

  # Counted first, so hanging up mid-request doesn't buy a free guess.
  test "every attempt is counted, right or wrong" do
    record, code = LoginCode.issue!(product: @product, email: @email)
    record.verify!(wrong(code))
    record.verify!(code)

    assert_equal 2, record.reload.attempts
  end

  private
    def wrong(code) = format("%06d", (code.to_i + 1) % 1_000_000)
end
