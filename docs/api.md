<img src="../public/icon.svg" alt="Licencio" width="40" height="40" align="left">

# API reference

Every HTTP endpoint Licencio exposes, grouped by who calls it. Request bodies are JSON
unless noted. `:slug` is a Product's slug and `:product_id` is its UUID.

## Auth at a glance

| Credential | Header | Who holds it |
|------------|--------|--------------|
| Product API key (`prod_…`) | `X-Api-Key` | your app. Public, since it ships in the binary |
| Product issuance key | `X-Api-Key` | a bundle store. Secret |
| `ADMIN_API_KEY` | `Authorization: Bearer …` | you, for imports and revokes. Secret |
| `SUPPORT_ADMIN_TOKEN` | `X-Admin-Token` | you, for unlock support. Secret |
| Stripe or Apple signature | set by the sender | Stripe and Apple |
| none | | public endpoints, all rate limited per IP |

## Your app

Details and examples in [client integration](client-integration.md).

| Method and path | Auth | What it does | Limit |
|-----------------|------|--------------|-------|
| `POST /api/licenses/activate` | API key | activates a device (or starts a trial) and returns `{ jwt, public_key, customer }` | 30/min |
| `DELETE /api/licenses/deactivate` | API key | frees a device's seat. `204` on success | 30/min |
| `POST /api/licenses/validate` | none | does this key unlock the app? No token, no seat. CORS open | 5/min |

## Your website

Details and examples in the [operating guide](operating-guide.md#4-sell-from-your-website).

| Method and path | Auth | What it does | Limit |
|-----------------|------|--------------|-------|
| `GET /api/checkout?product_slug=…&price_id=…` | none | redirects to Stripe Checkout. For plain `<a>` buy links | 20/min |
| `POST /api/checkout` | none | same session, returned as `{ url }` | 20/min |
| `GET /api/products/:slug/variants` | none | the Product's Stripe prices, cheapest first | 30/min |
| `GET /api/products/:slug/stats` | none | `{ customers }`, the distinct customer count | 30/min |
| `POST /api/licenses/recover` | API key | `{ email }`. Emails the buyer their keys and a portal link. Always `200`. Call it from your server | 5/min |
| `POST /api/students/discount` | none | emails a student discount code to a school address. See [optional features](optional-features.md#student-discount) | 5/min |

Checkout takes these fields: `product_slug` and `price_id` (required), and `email`,
`renew_license_key`, `upgrade_license_key`, `promo`, `client_reference_id`, `gift` (`1` for
a gift purchase) and `region` (a signed region token) as options.

## Pages for buyers

| Path | What it is |
|------|------------|
| `/portal/recoveries/new?product=:slug` | the "lost your license?" form |
| `/portal` | the portal. Buyers reach it through a magic link |
| `/portal/renewals/new?license_key=…` | renew a `time_limited` license. Public, keyed on the license key |
| `/portal/upgrades/new?license_key=…&product=:slug` | add seats to a license. Public, keyed on the license key |
| `/redeem?product=:slug` | redeem a deal code. See [deal codes](deal-codes.md) |

## Unlock by email

Details in [unlock by email](unlock-by-email.md). All are CORS open.

| Method and path | Auth | What it does | Limit |
|-----------------|------|--------------|-------|
| `POST /v1/unlock/request` | none | `{ product_slug, email }`. Emails a 6-digit code if the address bought. Always `{ ok: true }` | 10/hour |
| `POST /v1/unlock/verify` | none | `{ product_slug, email, code, device_id }` → `{ ok, token, tier, updates_until, platforms }` | 10/min |
| `POST /v1/support/lookup` | support token | `{ product_slug, email, resend_code? }` → that address's purchases, and optionally a fresh code | 10/min |

## Gifts and the App Store

Details in [optional features](optional-features.md). All are CORS open.

| Method and path | Auth | What it does | Limit |
|-----------------|------|--------------|-------|
| `GET /v1/gifts/:code?product_slug=…` | none | the gift card: `{ code, tier, to, from, note, state }` | 30/min |
| `GET /v1/gifts/checkout/:session_id?product_slug=…` | none | the same card, found by its Stripe session. `404` means the webhook hasn't landed yet, so ask again | 30/min |
| `POST /v1/gifts/:code/redeem` | none | `{ product_slug, email }`. Gives the license to that address | 10/hour |
| `POST /v1/iap/claim` | the signed transaction | `{ product_slug, email, jws, newsletter }`. Turns an App Store purchase into a license | 10/hour |

## Admin and integrations

| Method and path | Auth | What it does | Limit |
|-----------------|------|--------------|-------|
| `POST /api/admin/migrations/import` | admin key | bulk-imports licenses. See [moving from another store](operating-guide.md#7-move-from-another-store) | 5/min |
| `POST /api/admin/redemption_codes/revoke` | admin key | `{ code }`. Revokes a deal code and takes back its seat | 5/min |
| `GET /api/admin/products/:slug/trials?from=YYYY-MM-DD&to=YYYY-MM-DD` | admin key | trials started, bought, expired and running in that window | 5/min |
| `GET /api/admin/products/:slug/trials/cohorts` | admin key | trial to paid by the week each trial started, last 8 weeks, newest first | 5/min |
| `POST /api/licenses/issue` | issuance key | `{ email, name?, seats? }`. Issues a license for a bundle store and returns the bare key as plain text | |

The 5/min admin limit is shared across all `/api/admin/*` calls.

## Webhooks

| Path | Sender | What it handles |
|------|--------|-----------------|
| `POST /webhooks/stripe/:product_id` | Stripe | `checkout.session.completed` issues and emails the license. `charge.refunded` revokes it on a full refund. Verified with that Product's `stripe_webhook_secret` |
| `POST /webhooks/app_store/:product_id` | Apple | App Store Server Notifications V2. `REFUND` and `REVOKE` revoke the license. Everything else gets `200` so Apple stops retrying |

## Health

`GET /up` and `GET /health` return `200` when the app boots. Both skip the HTTPS redirect,
so a load balancer can probe over plain HTTP.

## Errors

Every JSON error looks like this. Branch on `code`. The `error` text is written for a
person and can change.

```json
{ "error": "All seats for this license are in use.", "code": "seat_limit_reached" }
```

A `429` (rate limited) has an empty body.

| `code` | HTTP | Meaning |
|--------|------|---------|
| `unauthorized` | 401 | missing or wrong key |
| `license_not_found` | 404 | no license with that key for this Product |
| `license_expired` | 403 | a finished trial, or an expired license that isn't `time_limited` |
| `license_refunded` | 403 | the license was refunded |
| `license_inactive` | 403 | the license was deactivated |
| `license_not_eligible` | 403 | validate: the key is a trial |
| `seat_limit_reached` | 409 | every seat is in use |
| `trial_unavailable` | 403 | no key sent and the Product has no trial |
| `missing_hardware_id` | 422 | activate or deactivate without `hardware_id` |
| `device_not_active` | 404 | deactivate: that device had no seat |
| `price_not_found` | 404 | checkout: the price is gone, or isn't this Product's |
| `product_not_found` | 404 | no Product with that slug |
| `invalid_seats` | 422 | issue: seats must be 1 to 10, or `unlimited` where the Product allows it |
| `invalid_email` | 422 | that isn't an email address |
| `not_academic_email` | 422 | student discount: not a school address |
| `student_discount_unavailable` | 503 | student discount isn't set up for this Product |
| `code_invalid` | 422 | unlock: wrong code, or no live code |
| `code_expired` | 410 | unlock: the code is older than 10 minutes |
| `too_many_attempts` | 429 | unlock: 5 wrong guesses burned the code |
| `purchase_refunded` | 403 | unlock: that purchase was refunded |
| `purchase_not_found` | 404 | unlock: no purchase for that address |
| `transaction_invalid` | 422 | App Store claim: Apple didn't confirm the purchase |
| `gift_not_found` | 404 | no gift with that code |
| `gift_redeemed` | 409 | the gift was already opened |
| `gift_refunded` | 410 | the gift was refunded |

Checkout returns a bare `503` when the Product isn't set up to sell that price (missing
Stripe keys or URLs, or no seat count).
