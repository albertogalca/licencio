# A stand-in for Apple's App Store signing chain: a root, an intermediate and a leaf carrying
# the same marker extensions Apple's do, so AppStoreTransaction.verify runs for real against
# a root the test installs in place of Apple's.
class AppStoreSigning
  attr_reader :root

  def initialize(leaf_oid: AppStoreTransaction::LEAF_OID, intermediate_oid: AppStoreTransaction::INTERMEDIATE_OID)
    root_key, intermediate_key, @leaf_key = 3.times.map { OpenSSL::PKey::EC.generate("prime256v1") }
    @root = certificate("Test Root", root_key, ca: true)
    @intermediate = certificate("Test Intermediate", intermediate_key, ca: true,
      issuer: @root, issuer_key: root_key, marker: intermediate_oid)
    @leaf = certificate("Test Leaf", @leaf_key, ca: false,
      issuer: @intermediate, issuer_key: intermediate_key, marker: leaf_oid)
  end

  def self.transaction(**overrides)
    now = (Time.current.to_f * 1000).to_i
    { "transactionId" => "2000000111", "originalTransactionId" => "2000000111",
      "bundleId" => "studio.cantimplora.cozy", "productId" => "studio.cantimplora.cozy.lifetime",
      "type" => "Non-Consumable", "environment" => "Production",
      "purchaseDate" => now, "signedDate" => now, "price" => 49990, "currency" => "USD" }.merge(overrides)
  end

  def jws(payload = self.class.transaction, signing_key: @leaf_key)
    header = { alg: "ES256", x5c: [ @leaf, @intermediate, @root ].map { |c| Base64.strict_encode64(c.to_der) } }
    input = [ header, payload ].map { |part| Base64.urlsafe_encode64(JSON.generate(part), padding: false) }.join(".")
    halves = OpenSSL::ASN1.decode(signing_key.sign("SHA256", input)).value
    raw = halves.map { |half| half.value.to_s(2).rjust(32, "\0") }.join
    "#{input}.#{Base64.urlsafe_encode64(raw, padding: false)}"
  end

  private
    def certificate(name, key, ca:, issuer: nil, issuer_key: key, marker: nil)
      cert = OpenSSL::X509::Certificate.new
      cert.version = 2
      cert.serial = SecureRandom.random_number(2**64)
      cert.subject = OpenSSL::X509::Name.parse("/CN=#{name}")
      cert.issuer = issuer ? issuer.subject : cert.subject
      cert.public_key = key
      cert.not_before = 1.year.ago
      cert.not_after = 1.year.from_now
      factory = OpenSSL::X509::ExtensionFactory.new(issuer || cert, cert)
      cert.add_extension(factory.create_extension("basicConstraints", ca ? "CA:TRUE" : "CA:FALSE", true))
      cert.add_extension(factory.create_extension("keyUsage", ca ? "keyCertSign,cRLSign" : "digitalSignature", true))
      cert.add_extension(factory.create_extension("subjectKeyIdentifier", "hash"))
      cert.add_extension(OpenSSL::X509::Extension.new(marker, OpenSSL::ASN1::Null.new(nil).to_der)) if marker
      cert.sign(issuer_key, "SHA256")
      cert
    end
end
