<img src="../public/icon.svg" alt="Licencio" width="40" height="40" align="left">

# Client integration

This is for the app side: how your app activates a license key, stores the token, and
checks it offline on every launch.

The short version: your app calls one endpoint once, gets back a signed token, and from
then on verifies that token itself with a public key baked into the build. It only calls
the server again to refresh the token every few days.

## The flow

1. The buyer pastes their key. Your app sends it to `POST /api/licenses/activate` with a
   device id and a random nonce.
2. Licencio takes a seat and returns a signed token (a JWT).
3. Your app saves the token, the device id and the nonce.
4. On every launch, your app verifies the token offline. No network.
5. When the app is online and the token is a few days old, it calls activate again in the
   background to get a fresh one. That refresh is how refunds reach the device.

## What you embed in the app

| Value | Where it comes from | Secret? |
|-------|---------------------|---------|
| Product API key (`prod_…`) | the Product's edit page in `/admin` | no. It ships in your binary, so anyone can read it |
| Ed25519 public key | the Product's edit page (`eddsa_public_key`) | no. It's safe to publish |

The activation response also returns the public key, but embed it at build time and trust
that copy. A key you fetch over the network is a key someone can swap.

If your app can't hold the API key at all (an App Store app on iPhone, say), use
[validate](#checking-a-key-without-the-api-key) instead.

## Activate a device

```bash
curl -X POST https://YOUR_HOST/api/licenses/activate \
  -H "X-Api-Key: prod_xxxxxxxxxxxxxxxx" \
  -H "Content-Type: application/json" \
  -d '{
    "license_key": "MYAPP-2C295B41-135C-4C2B-AFA6-5DEB9C05A733",
    "hardware_id": "<stable id for this device>",
    "device_name": "Ada’s MacBook Air",
    "nonce": "<random string>"
  }'
```

| Field | Required | Notes |
|-------|----------|-------|
| `license_key` | for a paid license | leave it out to start or resume a [trial](#trials) |
| `hardware_id` | yes | your own stable id for this install. Generate a UUID once and keep it |
| `nonce` | yes | a random string. It's echoed in the token so a token copied from another device fails your check |
| `device_name` | no | shown to the buyer in the portal, so they know which device to free |
| `machine_id` | trials only | see [trials](#trials) |

The response:

```json
{
  "jwt": "eyJhbGciOiJFZERTQSIsInR5cCI6IkpXVCJ9.<payload>.<signature>",
  "public_key": "3Jb9…=",
  "customer": { "name": "Ada Lovelace", "email": "ada@example.com" }
}
```

`customer` lets you show "Licensed to ada@example.com". It's `null` for a trial or a
license nobody has claimed yet.

Activating a device that's already active doesn't take another seat, so re-activating to
refresh the token is safe.

## The token

A compact JWT: `base64url(header).base64url(payload).base64url(signature)`.

The header is `{"alg":"EdDSA","typ":"JWT"}`, sometimes with a `kid` naming which key signed
it. The payload:

| Claim | Meaning |
|-------|---------|
| `hardware_id` | the device id you sent. Check it matches this device |
| `nonce` | the nonce you sent. Check it matches what this device saved |
| `license_key` | the license this token belongs to |
| `update_eligible` | `true` if this license includes the current version's updates |
| `expires_at` | ISO 8601 time, or `null`. See [what expires_at means](#what-expires_at-means) |
| `iat` | issued at, in Unix seconds |
| `exp` | the token's lease, in Unix seconds. Refresh before this |

The signature is Ed25519 over the ASCII bytes of the first 2 segments joined by `.`.

### What `expires_at` means

It depends on the license, and getting this wrong locks out paying customers.

| License | When `expires_at` passes |
|---------|--------------------------|
| a [trial](#trials) | the trial is over. Lock the app |
| a `time_limited` license (e.g. a year of updates) | updates stop, the app keeps working. `update_eligible` becomes `false` and activation keeps succeeding |
| any other license with an expiry | Licencio refuses the next refresh with `license_expired`, and you lock then |

So for a license key, don't lock on `expires_at` yourself. Gate updates on
`update_eligible`, and lock when a refresh comes back with a `403`. For a trial, lock when
`expires_at` passes.

## Verify the token

Any language with Ed25519 can do this, with no JWT library:

1. Split the token on `.` into 3 segments.
2. Base64url-decode segment 3. That's the signature.
3. Verify the signature over the ASCII bytes of `segment1 + "." + segment2` (still encoded)
   with your embedded public key. That key is standard base64 of the raw 32-byte Ed25519
   key. If verification fails, reject the token.
4. Base64url-decode segment 2 and parse the JSON.
5. Check `hardware_id` and `nonce` match what this device saved. Accept `"*"` for both,
   which is a [rescue token](operating-guide.md#8-if-this-server-ever-goes-away).
6. Apply [the `expires_at` rules](#what-expires_at-means) and gate updates on
   `update_eligible`.
7. If `exp` has passed, the token is stale. Refresh it when you're online. Whether you
   lock a stale token straight away or give an offline user some grace is up to you.

Base64url is base64 with `-` for `+`, `_` for `/`, and no `=` padding. Restore those before
decoding with a standard base64 decoder.

The Ed25519 call by platform: Node `crypto.verify(null, data, key, signature)`, Python
`cryptography`'s `Ed25519PublicKey.verify`, Go `ed25519.Verify`, Rust `ed25519-dalek`,
Swift `Curve25519.Signing` (below).

### Swift (macOS, iOS), with CryptoKit and no dependencies

```swift
import CryptoKit
import Foundation

enum LicenseError: Error { case malformed, badSignature, wrongDevice, trialOver }

struct LicenseClaims: Decodable {
    let hardware_id: String
    let license_key: String
    let expires_at: String?
    let update_eligible: Bool
    let nonce: String
    let iat: Int
    let exp: Int

    /// Past its 7-day lease. Refresh when online.
    var isStale: Bool { Date(timeIntervalSince1970: TimeInterval(exp)) < Date() }
}

/// JWT segments are base64url without padding. Restore both before decoding.
private func base64urlDecode(_ s: String) -> Data? {
    var str = s.replacingOccurrences(of: "-", with: "+")
               .replacingOccurrences(of: "_", with: "/")
    while str.count % 4 != 0 { str += "=" }
    return Data(base64Encoded: str)
}

/// Verifies a Licencio token offline.
/// - publicKeyBase64: the product's public key, embedded at build time.
/// - expectedHardwareID / expectedNonce: what THIS device sent when it activated.
/// - isTrial: true when the device activated without a license key.
func verifyLicense(jwt: String,
                   publicKeyBase64: String,
                   expectedHardwareID: String,
                   expectedNonce: String,
                   isTrial: Bool) throws -> LicenseClaims {
    let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3,
          let signature = base64urlDecode(String(parts[2])),
          let payload = base64urlDecode(String(parts[1])),
          let keyBytes = Data(base64Encoded: publicKeyBase64)
    else { throw LicenseError.malformed }

    let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyBytes)
    let signingInput = Data("\(parts[0]).\(parts[1])".utf8)
    guard key.isValidSignature(signature, for: signingInput) else {
        throw LicenseError.badSignature
    }

    let claims = try JSONDecoder().decode(LicenseClaims.self, from: payload)

    // "*" is a rescue token: valid on every device.
    let deviceMatches = claims.hardware_id == "*" || claims.hardware_id == expectedHardwareID
    let nonceMatches = claims.nonce == "*" || claims.nonce == expectedNonce
    guard deviceMatches, nonceMatches else { throw LicenseError.wrongDevice }

    // Only a trial ends at expires_at. A paid license's expiry ends updates, not the app.
    if isTrial,
       let expiresAt = claims.expires_at,
       let date = ISO8601DateFormatter().date(from: expiresAt),
       date < Date() {
        throw LicenseError.trialOver
    }

    return claims
}
```

If it throws, the token is forged, damaged, for another device, or a finished trial. If it
returns, check `claims.update_eligible` before offering an update, and refresh in the
background when `claims.isStale`.

## Token lease and revocation

Verification is offline, so Licencio can't reach into a device and cancel a token. Instead
every token has a 7-day lease in `exp`.

Refresh it quietly in the background when the app is online: on launch, or once `exp` is a
couple of days away. A refresh is the same `POST /api/licenses/activate` with the same
`hardware_id`, and it doesn't cost a seat.

That refresh is what makes refunds work. Once a license is refunded or deactivated, the
next refresh returns a `403` (`license_refunded` or `license_inactive`) instead of a token,
and your app locks. An online app locks within a day or so. A device that stays fully
offline keeps working until its lease runs out, up to 7 days.

`exp` and `expires_at` are different things. `exp` is how long this token is fresh.
`expires_at` belongs to the license itself.

## Free a seat

When the buyer signs out of your app or moves it to another device, release the seat:

```bash
curl -X DELETE https://YOUR_HOST/api/licenses/deactivate \
  -H "X-Api-Key: prod_xxxxxxxxxxxxxxxx" \
  -H "Content-Type: application/json" \
  -d '{"license_key":"MYAPP-2C295B41-135C-4C2B-AFA6-5DEB9C05A733","hardware_id":"<this device>"}'
```

It returns `204` on success, or `404 device_not_active` if that device wasn't using a seat.
Buyers can also free seats from the portal.

## Trials

If the Product has `trial_days` set, activate without a `license_key` and you get a trial
token for that device. Calling it again on the same device returns the same trial, with
the same end date, so it's safe to call on every launch until the trial ends.

If the Product has no trial, you get `403 trial_unavailable`. Once the trial is over,
activation returns `403 license_expired`.

A trial is keyed on `hardware_id`, so a reinstall that loses that id would get a new trial.
To stop that, also send `machine_id`: a SHA-256 of the operating system's machine id, salted
with something specific to your app, as 64 hex characters. Licencio then keeps one trial
per machine. Anything that isn't 64 hex characters is ignored. A single IP can start 5
trials per Product per day.

When the buyer pays and enters their key, activate again with the `license_key` and switch
to the paid token.

## Checking a key without the API key

The API key can activate devices and start trials, and an iPhone app bundle is a zip anyone
can open. If your app can't hold the key, it can ask a simpler question instead: does this
key unlock the app?

```bash
curl -X POST https://YOUR_HOST/api/licenses/validate \
  -H "Content-Type: application/json" \
  -d '{"license_key":"MYAPP-2C295B41-…","product_slug":"my-app"}'
```

```json
{ "valid": true, "tier": "lifetime", "expires_at": "2027-07-31T00:00:00Z", "update_eligible": false }
```

This creates nothing and takes no seat. There's no signed token, so it can't be verified
offline and can't be revoked later. Cache the answer yourself, in the keychain for
example.

It's looser than activation on purpose. A license past its `expires_at` still returns
`valid: true` with `update_eligible: false`. Trials return `403 license_not_eligible`,
because a 7-day trial shouldn't buy a permanent unlock. Refunded and deactivated licenses
are refused as usual.

The endpoint allows 5 requests per minute per IP and answers CORS preflights with
`Access-Control-Allow-Origin: *`, so a web view (such as Capacitor on iOS) can call it.

## Errors

Every failure has a JSON body with a stable `code` and a readable `error`. Branch on
`code`, and show `error` or your own copy.

```json
{ "error": "This license was refunded.", "code": "license_refunded" }
```

| HTTP | `code` | When |
|------|--------|------|
| 401 | `unauthorized` | the `X-Api-Key` is missing or wrong |
| 404 | `license_not_found` | no license with that key for this Product. A key from another Product gets this too |
| 403 | `license_refunded` | the license was refunded |
| 403 | `license_inactive` | the license was deactivated |
| 403 | `license_expired` | a trial that's over, or a license with an expiry that isn't `time_limited` |
| 403 | `trial_unavailable` | no `license_key` sent and the Product has no trial |
| 403 | `license_not_eligible` | validate only: the key is a trial |
| 409 | `seat_limit_reached` | every seat is in use. Ask the buyer to free one in the portal |
| 422 | `missing_hardware_id` | activate or deactivate without a `hardware_id` |
| 404 | `device_not_active` | deactivate only: that device wasn't using a seat |
| 429 | none | rate limited, with an empty body. Activate allows 30 requests per minute per IP |

The full list across every endpoint is in the [API reference](api.md#errors).
