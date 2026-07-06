require "net/http"

module Loops
  ENDPOINT = URI("https://app.loops.so/api/v1/transactional")

  def self.send_transactional(api_key:, transactional_id:, email:, data:)
    request = Net::HTTP::Post.new(ENDPOINT)
    request["Authorization"] = "Bearer #{api_key}"
    request["Content-Type"]  = "application/json"
    request.body = JSON.generate(transactionalId: transactional_id, email:, dataVariables: data)

    response = Net::HTTP.start(ENDPOINT.host, ENDPOINT.port, use_ssl: true) do |http|
      http.request(request)
    end
    # Surface Loops rejections (bad/blank transactional_id, auth) instead of dropping
    # the email silently — the job then fails visibly and retries.
    raise "Loops #{response.code}: #{response.body}" unless response.is_a?(Net::HTTPSuccess)
    response
  end
end
