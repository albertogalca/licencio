require "test_helper"

class ProxyHeadersTest < ActionDispatch::IntegrationTest
  # /up passes through the whole middleware stack and is excluded from the SSL
  # and host-authorization redirects, so it isolates RemoteIp.
  test "a spoofed Client-Ip header does not raise" do
    get "/up", headers: {
      "Client-Ip" => "127.0.0.1",
      "X-Forwarded-For" => "203.0.113.7, 10.0.1.6"
    }

    assert_response :success
    assert_equal "203.0.113.7", request.remote_ip
  end

  test "a Forwarded header cannot override X-Forwarded-For" do
    get "/up", headers: {
      "Forwarded" => "for=1.2.3.4",
      "X-Forwarded-For" => "203.0.113.7, 10.0.1.6"
    }

    assert_response :success
    assert_equal "203.0.113.7", request.remote_ip
  end
end
