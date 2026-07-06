# Client integration — verifying a license offline

Licencio issues each activated device an **EdDSA (Ed25519) signed JWT**. Your app
verifies it **fully offline** with the product's public key — no network call after
activation, no shared secret in the client.

## The token

A Licencio license token is a compact JWT:

```
base64url(header) . base64url(payload) . base64url(signature)
```

- **header** — `{"alg":"EdDSA","typ":"JWT"}`
- **payload** (claims):

  | claim             | meaning                                                        |
  |-------------------|----------------------------------------------------------------|
  | `hardware_id`     | device you sent at activation — bind the token to this machine  |
  | `license_key`     | the license this token belongs to                              |
  | `expires_at`      | ISO-8601, or `null` for a lifetime/version-locked license      |
  | `update_eligible` | `true` if this device may install updates (per the license's update policy) |
  | `nonce`           | value you sent at activation — anti-replay for this device      |
  | `iat`             | issued-at (Unix seconds)                                       |

- **signature** — Ed25519 signature over the ASCII bytes of `base64url(header).base64url(payload)`
  (the first two segments joined by `.`).

## Getting a token

`POST /api/licenses/activate` with the product's device API key. You choose
`hardware_id` (stable per machine) and a random `nonce`:

```bash
curl -X POST https://your-host/api/licenses/activate \
  -H "X-Api-Key: prod_xxxxxxxxxxxxxxxx" \
  -H "Content-Type: application/json" \
  -d '{"license_key":"demo_ab12...","hardware_id":"<machine-uuid>","nonce":"<random>"}'
```

Response:

```json
{ "jwt": "eyJhbGci...<header>.<payload>.<sig>", "public_key": "3Jb9...=" }
```

Cache the `jwt`. Verify it against the product's `public_key` (standard base64 of the
raw 32-byte Ed25519 key) whenever the app launches — offline.

> **Recommended:** the public key is **static per product** and safe to publish, so
> embed it in your app at build time rather than trusting the value from the network.
> The activation response returns it only for convenience/bootstrapping.

## Swift (macOS / iOS) — CryptoKit, no dependencies

```swift
import CryptoKit
import Foundation

enum LicenseError: Error { case malformed, badSignature, expired, wrongDevice }

/// JWT segments are base64url without padding; restore it before decoding.
private func base64urlDecode(_ s: String) -> Data? {
    var str = s.replacingOccurrences(of: "-", with: "+")
               .replacingOccurrences(of: "_", with: "/")
    while str.count % 4 != 0 { str += "=" }
    return Data(base64Encoded: str)
}

struct LicenseClaims: Decodable {
    let hardware_id: String
    let license_key: String
    let expires_at: String?
    let update_eligible: Bool
    let nonce: String
    let iat: Int
}

/// Verifies a Licencio license JWT fully offline.
/// - publicKeyBase64: the product's `public_key` (standard base64) — ideally embedded at build time.
/// - jwt: the token returned by POST /api/licenses/activate.
/// - expectedHardwareID / expectedNonce: what THIS device sent when it activated.
func verifyLicense(jwt: String,
                   publicKeyBase64: String,
                   expectedHardwareID: String,
                   expectedNonce: String) throws -> LicenseClaims {
    let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3,
          let signature = base64urlDecode(String(parts[2])),
          let payload = base64urlDecode(String(parts[1])),
          let keyBytes = Data(base64Encoded: publicKeyBase64)
    else { throw LicenseError.malformed }

    let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyBytes)

    // Signed input is the first two segments, joined by "." — exactly as the server signed them.
    let signingInput = Data("\(parts[0]).\(parts[1])".utf8)
    guard key.isValidSignature(signature, for: signingInput) else {
        throw LicenseError.badSignature
    }

    let claims = try JSONDecoder().decode(LicenseClaims.self, from: payload)

    // Bind the token to this machine and this activation.
    guard claims.hardware_id == expectedHardwareID,
          claims.nonce == expectedNonce else {
        throw LicenseError.wrongDevice
    }

    // Enforce expiry (nil == lifetime).
    if let exp = claims.expires_at,
       let date = ISO8601DateFormatter().date(from: exp),
       date < Date() {
        throw LicenseError.expired
    }

    return claims
}
```

That's the whole client side: one signature check plus three field checks. If it
throws, the license is invalid, tampered, expired, or for another device.
