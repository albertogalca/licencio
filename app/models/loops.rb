require "net/http"

module Loops
  TRANSACTIONAL   = URI("https://app.loops.so/api/v1/transactional")
  CONTACTS_CREATE = URI("https://app.loops.so/api/v1/contacts/create")
  CONTACTS_UPDATE = URI("https://app.loops.so/api/v1/contacts/update")

  def self.send_transactional(api_key:, transactional_id:, email:, data:)
    request(Net::HTTP::Post, TRANSACTIONAL, api_key:,
      body: { transactionalId: transactional_id, email:, dataVariables: data })
  end

  # Upsert a mailing-list contact. Mirrors the cozy/picmal workers: create, and if the
  # contact already exists (409) update it with the same payload. Used to subscribe buyers
  # on purchase (subscribed: true) and unsubscribe them on refund (subscribed: false).
  def self.upsert_contact(api_key:, email:, source:, subscribed: true, first_name: nil, last_name: nil)
    body = { email:, firstName: first_name, lastName: last_name, source:, subscribed: }.compact
    response = request(Net::HTTP::Post, CONTACTS_CREATE, api_key:, body:, allow: [ "409" ])
    return response unless response.code == "409"
    request(Net::HTTP::Put, CONTACTS_UPDATE, api_key:, body:)
  end

  # Surface Loops rejections (bad/blank id, auth) instead of dropping the call silently — the
  # job then fails visibly and retries. `allow` lists non-2xx codes the caller handles itself.
  def self.request(klass, uri, api_key:, body:, allow: [])
    req = klass.new(uri)
    req["Authorization"] = "Bearer #{api_key}"
    req["Content-Type"]  = "application/json"
    req.body = JSON.generate(body)

    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(req) }
    unless response.is_a?(Net::HTTPSuccess) || allow.include?(response.code)
      raise "Loops #{response.code}: #{response.body}"
    end
    response
  end
  private_class_method :request
end
