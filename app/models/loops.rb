require "net/http"

module Loops
  ENDPOINT = URI("https://app.loops.so/api/v1/transactional")

  def self.send_transactional(api_key:, transactional_id:, email:, data:)
    request = Net::HTTP::Post.new(ENDPOINT)
    request["Authorization"] = "Bearer #{api_key}"
    request["Content-Type"]  = "application/json"
    request.body = JSON.generate(transactionalId: transactional_id, email:, dataVariables: data)

    Net::HTTP.start(ENDPOINT.host, ENDPOINT.port, use_ssl: true) do |http|
      http.request(request)
    end
  end
end
