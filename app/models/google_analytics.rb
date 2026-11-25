require "net/http"

# GA4 Measurement Protocol. The storefront measures the visit; only the webhook knows it ended in
# a sale, so the sale is sent from here under the ids the storefront put on the buy link.
module GoogleAnalytics
  COLLECT = URI("https://www.google-analytics.com/mp/collect")

  # Stripe amounts are in minor units, except in currencies that have none.
  ZERO_DECIMAL = %w[BIF CLP DJF GNF JPY KMF KRW MGA PYG RWF UGX VND VUV XAF XOF XPF].freeze

  # The browser's GA4 client and session, as the buy link carries them: "<client>.<session>",
  # where the client id is itself two numbers. Any other client_reference_id is somebody else's
  # id and names no GA4 visit.
  Visitor = Data.define(:client_id, :session_id) do
    def self.parse(reference)
      match = /\A(\d+\.\d+)\.(\d+)\z/.match(reference.to_s)
      new(client_id: match[1], session_id: match[2]) if match
    end
  end

  def self.value(amount, currency)
    ZERO_DECIMAL.include?(currency.to_s.upcase) ? amount : amount / 100.0
  end

  # No buyer data: no name, no email, no IP address. GA4 answers 2xx even to an event it drops,
  # so a success here means received, not counted.
  def self.send_purchase(measurement_id:, api_secret:, visitor:, transaction_id:, amount:, currency:, item:)
    uri = COLLECT.dup
    uri.query = URI.encode_www_form(measurement_id:, api_secret:)
    req = Net::HTTP::Post.new(uri)
    req["Content-Type"] = "application/json"
    req.body = JSON.generate(
      client_id: visitor.client_id,
      consent: { ad_user_data: "DENIED", ad_personalization: "DENIED" },
      events: [ { name: "purchase", params: {
        session_id: visitor.session_id, engagement_time_msec: 1,
        transaction_id:, value: value(amount, currency), currency: currency.to_s.upcase,
        items: [ { item_id: item, quantity: 1 } ] } } ])

    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(req) }
    raise "Google Analytics #{response.code}" unless response.is_a?(Net::HTTPSuccess)
    response
  end
end
