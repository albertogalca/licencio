# Cozy unlock launch runbook

Ordered. Each step assumes the one before it is done. Nothing here is reversible in a
hurry — step 2 in particular can only be done once, and only before clients ship.

The license-key system stays live throughout. Every existing key keeps working, every
existing endpoint keeps answering. This adds a second way in, it does not replace one.

---

## 1. Deploy the server

```bash
bin/rails db:migrate
```

Set the new environment variable and restart:

```bash
SUPPORT_ADMIN_TOKEN=$(openssl rand -hex 32)   # keep it in the password manager
```

Check `/up` answers, then confirm the new routes exist:

```bash
curl -sS -X POST https://$APP_HOST/v1/unlock/request \
  -H 'Content-Type: application/json' \
  -d '{"product_slug":"cozy","email":"nobody@example.com","platform":"mac"}'
# → {"ok":true}   (an unknown address is answered exactly like a customer's)
```

---

## 2. Mint the backup signing key — before any client ships

Unlock tokens are verified offline, forever, by installs that may never contact this
server again. A key can only be rotated if every client **already** trusts the
replacement, so both public keys have to be in the very first build. There is no way to
add one later.

```bash
bin/rails "unlock:generate_backup_key[cozy]"
```

It prints the private half **once**. Put it in cold storage now — a password manager, or
paper in a drawer. It is stored nowhere on the server: only the public half is saved.

Then embed **both** public keys in every client (Mac, Windows, iPhone), keyed by the
token header's `kid`:

```json
{ "a": "<products.eddsa_public_key>", "b": "<products.eddsa_backup_public_key>" }
```

The client reads `kid` from the JWT header, picks that key, and verifies. `a` signs
today. Rotating later means restoring the cold private key and setting
`products.eddsa_key_id = "b"` — no client needs updating.

While you're here, also keep `rake "licenses:signing_key[cozy]"` output in cold storage
if you haven't: it is the same insurance for the license-key system.

---

## 3. Backfill the existing customers

Everyone who bought before today has to be able to unlock. Preview first:

```bash
DRY_RUN=1 bin/rails "unlock:backfill_purchases[cozy]"
```

Read the tally. `created` should be roughly the number of claimed, non-trial Cozy
licenses; `skipped` is trials, unclaimed imports, and licenses that say nothing about
updates. If the numbers look wrong, stop — this is the moment to find out.

```bash
bin/rails "unlock:backfill_purchases[cozy]"
```

Idempotent: re-running reports `existing`, not duplicates.

Verify against one real customer you can recognize:

```bash
curl -sS -X POST https://$APP_HOST/v1/support/lookup \
  -H "X-Admin-Token: $SUPPORT_ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"product_slug":"cozy","email":"a.real.buyer@gmail.com"}'
```

Their tier, purchase date and updates window should match what they actually bought.

---

## 4. Loops templates

Create two transactional templates in Loops:

- **Unlock code** — data variables `code`, `product_name`. This is the whole flow; if it
  doesn't arrive, nobody unlocks. Keep it plain, keep the six digits large, and say the
  code expires in ten minutes.
- **Education discount** — data variables `discount_code`, `pricing_url`, `product_name`,
  `sender_email`.

Then set on the Cozy product in `/admin`:

- `unlock_transactional_id` → the unlock code template
- `student_transactional_id` → the education template
- `student_discount_code` → `COZYEDU`

Send yourself a real code end to end before moving on.

---

## 5. Stripe prices

```bash
bin/rails runner scripts/stripe_prices.rb              # dry run — read the output
bin/rails runner scripts/stripe_prices.rb -- --apply
```

Creates, on Cozy's own Stripe account:

| Price | Amount | `tier` | `update_policy` |
|-------|--------|--------|-----------------|
| `cozy_standard_usd` | $49 | standard | time_limited |
| `cozy_forever_usd` | $89 | forever | lifetime |
| `cozy_standard_ppp_a` | $29 | standard | time_limited |
| `cozy_standard_ppp_b` | $19 | standard | time_limited |

…plus the `COZYEDU` promotion code (40% off). **Edit `PPP_BANDS` in the script first** —
the country lists are a judgement call, not a formula.

Two things to know:

- PPP is honour-system. `ppp_countries` rides in the price metadata and the webhook only
  **logs** `ppp.country_mismatch`. Nothing is blocked, nothing is voided. A VPN defeats
  any check, and a traveller with a foreign card is far more common than fraud.
- Stripe scopes a coupon by product, not by price, so `COZYEDU` would also discount the
  forever tier if someone found it there. Only offer the promo field on the standard
  checkout.

Buy each price once in test mode and confirm a `Purchase` row appears with the right
tier.

---

## 6. iOS build

Ship the build with both public keys embedded (step 2) and the unlock screen pointed at
`/v1/unlock/request` and `/v1/unlock/verify`. Keep `MONETIZATION_ENABLED` **off** — the
build goes through review while the flow is dark.

---

## 7. Launch day

In this order, within the same hour:

1. Flip `MONETIZATION_ENABLED` on in mobile.
2. Deploy the marketing site with the new pricing.
3. Send the grandfathering email to existing customers: they keep everything they have,
   plus iPhone at no cost. Say it plainly — this is the email that decides whether the
   change reads as generous or as a rug pull.

---

## Smoke tests

Run all of these against production on launch day.

- [ ] **Test-mode purchase** → a `purchases` row appears with the right `tier`,
      `updates_until` and `provider_order_id`.
- [ ] **Three devices, one address** → request + verify from three machines with the same
      email; all three succeed, all three get different tokens, none is refused.
- [ ] **Refund** → refund the test purchase, then request a code for that address:
      `{ ok: true }`, and no email arrives.
- [ ] **Six wrong codes** → the sixth answers `429 too_many_attempts`, and the correct
      digits no longer work afterwards.
- [ ] **Token verifies** → take a returned token, split it, and check the signature
      against the public key with the matching `kid`. Confirm there is no `exp` claim.
- [ ] **Existing license key still activates** → nothing above touched that path, and
      this is the check that proves it.

### The two calls, verbatim

```bash
# 1. Ask for a code. Always {"ok":true} — buyer, stranger or throttled.
curl -sS -X POST https://licenses.cozy.app/v1/unlock/request \
  -H 'Content-Type: application/json' \
  -d '{
        "product_slug": "cozy",
        "email": "ana.perez@gmail.com",
        "platform": "mac"
      }'
# → {"ok":true}

# 2. Spend it. Six digits, ten minutes, five wrong guesses.
curl -sS -X POST https://licenses.cozy.app/v1/unlock/verify \
  -H 'Content-Type: application/json' \
  -d '{
        "product_slug": "cozy",
        "email": "ana.perez@gmail.com",
        "code": "418302",
        "device_id": "9F3C-…-A1",
        "platform": "mac"
      }'
# → {"ok":true,
#    "token":"eyJhbGciOiJFZERTQSIsInR5cCI6IkpXVCIsImtpZCI6ImEifQ…",
#    "tier":"forever",
#    "updates_until":null,
#    "platforms":["mac","windows","iphone"]}

# Support, when someone writes in.
curl -sS -X POST https://licenses.cozy.app/v1/support/lookup \
  -H "X-Admin-Token: $SUPPORT_ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"product_slug":"cozy","email":"ana.perez@gmail.com","resend_code":true}'
```

Failures answer with the same contract as the rest of the API — a stable `code` plus a
human `error`: `invalid_email` (422), `code_invalid` (422), `code_expired` (410),
`too_many_attempts` (429), `purchase_refunded` (403), `purchase_not_found` (404),
`product_not_found` (404).
