<img src="../public/icon.svg" alt="Licencio" width="40" height="40" align="left">

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
  | `exp`             | token **lease** expiry (Unix seconds) — re-activate to renew before this (see below) |

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

## Token lease & revocation

Verification is fully offline, so the server can't reach out to revoke a token it
already issued. Instead every token carries a short lease: the `exp` claim, set
7 days from issue. Your app should reject a token past its `exp` and re-activate
(the same `POST /api/licenses/activate`) to get a fresh one.

Do this quietly in the background while you're online — on launch, or once `exp`
gets close. Re-activating the same `hardware_id` is idempotent, so it's cheap.

That's what makes revocation work. Once a license is refunded or deactivated, its
next re-activation returns a `403` (`license_refunded` / `license_inactive`) instead
of a new token, and your app locks. The catch is the lease window: a device that
stays fully offline keeps working until `exp`, up to 7 days, while an online app
re-activates and revokes almost immediately. And `exp` isn't `expires_at` — `exp`
is the token's freshness lease, `expires_at` is the license's own validity (`null`
for lifetime).

## Error responses

Any failed request returns a JSON body with a stable machine `code` and a human
`error` string — branch on `code`, show `error` (or your own copy) to the user:

```json
{ "error": "This license has expired.", "code": "license_expired" }
```

| HTTP | `code` | When |
|------|--------|------|
| 401 | `unauthorized` | missing/wrong `X-Api-Key` |
| 404 | `license_not_found` | no license matches that key **for this product** (wrong key, or a key from another product) |
| 403 | `license_expired` | license is past its `expires_at` |
| 403 | `license_refunded` | license was refunded |
| 403 | `license_inactive` | license was manually deactivated |
| 403 | `trial_unavailable` | no `license_key` sent and the product offers no trial |
| 409 | `seat_limit_reached` | all device seats are in use |
| 404 | `device_not_active` | (deactivate) that `hardware_id` isn't currently active |

A successful activation of a device that's already active is idempotent — it
returns the same `{ jwt, public_key }`, not an error.

## Freeing a seat

`DELETE /api/licenses/deactivate` with the same `X-Api-Key`, the `license_key`, and
the `hardware_id` to release. Returns `204 No Content` on success, or
`device_not_active` (404) if that device wasn't active.

```bash
curl -X DELETE https://your-host/api/licenses/deactivate \
  -H "X-Api-Key: prod_xxxxxxxxxxxxxxxx" \
  -H "Content-Type: application/json" \
  -d '{"license_key":"demo_ab12...","hardware_id":"<machine-uuid>"}'
```

## Verify a token in any language

The whole check is one Ed25519 signature verification plus a few field checks.
Any language with an Ed25519 primitive can do it — no JWT library required:

1. **Split** the JWT on `.` into three segments: header, payload, signature.
2. **base64url-decode** the signature (segment 3). The bytes that were signed are
   the ASCII of `segment1 + "." + segment2` (header and payload, joined by a dot,
   *before* decoding).
3. **Verify** that signature over those bytes with the product's public key —
   standard base64 of the raw 32-byte Ed25519 key. Reject the token if it fails.
4. **base64url-decode** the payload (segment 2) into JSON. Confirm `hardware_id`
   and `nonce` match what *this* device sent at activation.
5. **Enforce the claims yourself:** reject if `expires_at` is in the past (`null`
   means lifetime — never expires); gate updates on `update_eligible`. Also treat a
   token past its `exp` lease as stale — re-activate to renew it (see "Token lease &
   revocation" above).

The Ed25519 primitive by platform: Node `crypto.verify('ed25519', …)`, Python
`cryptography`'s `Ed25519PublicKey.verify`, Go `ed25519.Verify`, Rust `ed25519-dalek`,
Swift `Curve25519.Signing` (below). base64url = base64 with `-`→`+`, `_`→`/`, and
`=` padding restored.

## Swift (macOS / iOS) — CryptoKit, no dependencies

```swift
import CryptoKit
import Foundation

enum LicenseError: Error { case malformed, badSignature, expired, leaseExpired, wrongDevice }

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
    let exp: Int
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

    // Enforce license expiry (nil == lifetime).
    if let expiresAt = claims.expires_at,
       let date = ISO8601DateFormatter().date(from: expiresAt),
       date < Date() {
        throw LicenseError.expired
    }

    // Enforce the token lease: past exp, re-activate to renew (revocation takes effect here).
    if Date(timeIntervalSince1970: TimeInterval(claims.exp)) < Date() {
        throw LicenseError.leaseExpired
    }

    return claims
}
```

That's the whole client side: one signature check plus a few field checks. If it
throws, the license is invalid, tampered, expired, past its lease, or for another
device — on `leaseExpired`, re-activate to renew.
