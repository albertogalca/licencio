require "net/http"

# Server-side event capture. The marketing site tags each Stripe checkout with the
# visitor's PostHog distinct_id (Product#checkout_session_params, client_reference_id),
# so reporting the purchase under that same id joins it to the pageviews that led to it.
# Without this, PostHog sees buy_clicked and never learns whether the sale happened.
module Posthog
  DEFAULT_HOST = "https://eu.i.posthog.com".freeze

  def self.capture(api_key:, distinct_id:, event:, properties: {}, timestamp: nil)
    body = { api_key:, event:, distinct_id:, properties:, timestamp: timestamp&.iso8601 }.compact
    uri = URI("#{ENV.fetch('POSTHOG_HOST', DEFAULT_HOST)}/capture/")

    req = Net::HTTP::Post.new(uri)
    req["Content-Type"] = "application/json"
    req.body = JSON.generate(body)

    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(req) }
    # Surface rejections (bad key, malformed body) so the job fails visibly and retries,
    # rather than silently losing revenue data the way the Lemon Squeezy worker did.
    raise "PostHog #{response.code}: #{response.body}" unless response.is_a?(Net::HTTPSuccess)
    response
  end
end
