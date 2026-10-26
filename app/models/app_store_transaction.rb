# A StoreKit 2 transaction whose signature has been checked. The only way to get one is
# `verify`, so everything that receives one trusts it without looking again.
class AppStoreTransaction < Data.define(:original_transaction_id, :transaction_id, :product_id,
  :bundle_id, :environment, :purchase_date, :revocation_date, :amount_cents, :currency, :storefront)
  Invalid = Class.new(StandardError)
  Notification = Data.define(:type, :transaction)

  # Apple marks its two signing certificates with these extensions. A chain to the root
  # alone is not enough: Apple's root signs plenty of intermediates that never sign purchases.
  LEAF_OID = "1.2.840.113635.100.6.11.1"
  INTERMEDIATE_OID = "1.2.840.113635.100.6.2.1"

  ENVIRONMENTS = { "Production" => "production", "Sandbox" => "sandbox" }.freeze

  # What each App Store product grants, keyed by its product id. The values mirror the
  # Stripe price it stands in for (cozy_standard_usd in scripts/stripe_prices.rb), so a
  # claim mints the same license that price would.
  GRANTS = {
    "studio.cantimplora.cozy.lifetime" => { product_slug: "cozy", bundle_id: "studio.cantimplora.cozy",
      tier: "standard", update_policy: "time_limited", seats: nil }
  }.freeze

  class << self
    # Apple Root CA - G3, from https://www.apple.com/certificateauthority/AppleRootCA-G3.cer
    # (SHA-256 63:34:3A:BF:...:3E:91:79). Tests swap in their own root.
    attr_writer :trusted_root

    def trusted_root
      @trusted_root ||= OpenSSL::X509::Certificate.new(
        File.binread(Rails.root.join("config/certs/AppleRootCA-G3.cer")))
    end

    def verify(jws)
      from_payload(verified_payload(jws))
    rescue JSON::ParserError, ArgumentError, TypeError, KeyError, OpenSSL::OpenSSLError => error
      raise Invalid, error.class.name
    end

    # An App Store Server Notification V2, as Apple posts it to the webhook. The envelope is
    # signed like a transaction, and the transaction inside it is verified on its own.
    def verify_notification(signed_payload)
      payload = verified_payload(signed_payload)
      data = payload["data"]
      signed_transaction = data["signedTransactionInfo"] if data.is_a?(Hash)
      Notification.new(type: payload.fetch("notificationType"),
        transaction: signed_transaction && verify(signed_transaction))
    rescue JSON::ParserError, ArgumentError, TypeError, KeyError, OpenSSL::OpenSSLError => error
      raise Invalid, error.class.name
    end

    private
      def verified_payload(jws)
        parts = jws.to_s.split(".", -1)
        raise Invalid, "malformed" unless parts.size == 3
        header, payload = parts.first(2).map { |part| JSON.parse(decode(part)) }
        raise Invalid, "malformed" unless header.is_a?(Hash) && payload.is_a?(Hash)
        raise Invalid, "alg" unless header["alg"] == "ES256"

        leaf, intermediate = Array(header["x5c"]).first(2).map do |der|
          OpenSSL::X509::Certificate.new(Base64.strict_decode64(der.to_s))
        end
        raise Invalid, "x5c" unless leaf && intermediate
        # Checked at the time Apple signed, as Apple's own server library does by default, so a
        # buyer holding an older transaction is not refused once a leaf certificate expires.
        verify_chain!(leaf, intermediate, at: Time.zone.at(Integer(payload.fetch("signedDate")) / 1000))
        verify_signature!(leaf, "#{parts[0]}.#{parts[1]}", decode(parts[2]))
        payload
      end

      def decode(part) = Base64.urlsafe_decode64(part)

      def verify_chain!(leaf, intermediate, at:)
        store = OpenSSL::X509::Store.new
        store.add_cert(trusted_root)
        store.time = at
        context = OpenSSL::X509::StoreContext.new(store, leaf, [ intermediate ])
        raise Invalid, "chain: #{context.error_string}" unless context.verify
        # The verified path must run through the intermediate that was sent, not around it.
        raise Invalid, "chain" unless context.chain.map(&:to_der) ==
          [ leaf, intermediate, trusted_root ].map(&:to_der)
        raise Invalid, "leaf" unless marked?(leaf, LEAF_OID)
        raise Invalid, "intermediate" unless marked?(intermediate, INTERMEDIATE_OID)
      end

      def marked?(certificate, oid) = certificate.extensions.any? { |extension| extension.oid == oid }

      # JWS carries ES256 as raw r||s; OpenSSL verifies the DER sequence of the two integers.
      def verify_signature!(leaf, signing_input, signature)
        key = leaf.public_key
        raise Invalid, "key" unless key.is_a?(OpenSSL::PKey::EC) && key.group.curve_name == "prime256v1"
        raise Invalid, "signature" unless signature.bytesize == 64
        der = OpenSSL::ASN1::Sequence([ signature.byteslice(0, 32), signature.byteslice(32, 32) ]
          .map { |half| OpenSSL::ASN1::Integer(OpenSSL::BN.new(half, 2)) }).to_der
        raise Invalid, "signature" unless key.verify("SHA256", der, signing_input)
      end

      def from_payload(payload)
        new(original_transaction_id: payload.fetch("originalTransactionId").to_s,
          transaction_id: payload.fetch("transactionId").to_s,
          product_id: payload.fetch("productId"),
          bundle_id: payload.fetch("bundleId"),
          environment: ENVIRONMENTS.fetch(payload.fetch("environment")),
          purchase_date: at_ms(payload.fetch("purchaseDate")),
          revocation_date: payload["revocationDate"] && at_ms(payload["revocationDate"]),
          # Apple states price in thousandths of the currency unit.
          amount_cents: payload["price"] && payload["price"].to_i / 10,
          currency: payload["currency"]&.downcase,
          # The App Store country the purchase was made in, ISO 3166-1 alpha-3 ("IND").
          storefront: payload["storefront"].to_s.then { |code| code if code.match?(/\A[A-Z]{3}\z/) })
      end

      def at_ms(value) = Time.zone.at(value.to_i / 1000.0)
  end

  # Whether this is a purchase of one of `product`'s App Store products, refunded or not.
  def for?(product)
    grant = GRANTS[product_id]
    grant.present? && grant[:product_slug] == product.slug && grant[:bundle_id] == bundle_id
  end

  # What this transaction entitles its holder to on `product`, or nil when it entitles them
  # to nothing there: another app's purchase, the $0 trial, or one Apple has refunded.
  def grant_for(product)
    GRANTS[product_id] if for?(product) && revocation_date.nil?
  end
end
