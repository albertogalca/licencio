<img src="../public/icon.svg" alt="Licencio" width="40" height="40" align="left">

# Unlock by email

A second way into your app, next to license keys. The buyer types their email, gets a
6-digit code, types it back, and the app is unlocked for good. No account, no password, no
key to lose, and no device limit.

License keys keep working as before. A Product can offer both at once.

## When to use it

It fits apps where the buyer's email is the identity: a Mac app with a free iPhone
companion, say, or a buyer who'll never keep track of a key. The trade-off is that it can't
be revoked. Once an install is unlocked, it stays unlocked, offline, forever. A refund
stops new unlocks for that address, not existing ones.

If you need seat limits or refunds that lock devices, use license keys.

## Setup

1. **Tag your Stripe Prices.** Only purchases of a Price whose metadata has a `tier`
   become unlockable. Use `standard` (a year of updates) or `forever`. The Stripe webhook
   records a purchase next to the license it already creates. Prices without a `tier` are
   left alone.
2. **Add the unlock-code email.** Create a Loops template with the `code` and
   `product_name` variables and paste its id into the Product's `unlock_transactional_id`.
   Copy for it is in [`email-templates/unlock-code.md`](email-templates/unlock-code.md).
   Without this template nobody can unlock, since the code is the only way in.
3. **Set `SUPPORT_ADMIN_TOKEN`** so you can look up a buyer's purchases when an unlock goes
   wrong. See [support](#support).
4. **Ship 2 public keys** in your app before the first release. See
   [key rotation](#key-rotation). This step can only be done before clients ship.

If you sold before turning this on, create purchases for your existing licenses:

```bash
DRY_RUN=1 bin/rails "unlock:backfill_purchases[my-app]"   # preview
bin/rails "unlock:backfill_purchases[my-app]"
```

## The flow

**Request a code.**

```bash
curl -X POST https://YOUR_HOST/v1/unlock/request \
  -H "Content-Type: application/json" \
  -d '{"product_slug":"my-app","email":"ada@example.com"}'
# → { "ok": true }
```

The answer is always `{ "ok": true }`, at the same speed, whether or not the address
bought anything. The check happens in a background job, so nobody can learn who your
customers are by timing it. Each address gets 3 codes per 15 minutes. Past that, the answer
is still `{ "ok": true }` and no email goes out.

**Verify the code.**

```bash
curl -X POST https://YOUR_HOST/v1/unlock/verify \
  -H "Content-Type: application/json" \
  -d '{"product_slug":"my-app","email":"ada@example.com","code":"123456","device_id":"<any id>"}'
```

```json
{
  "ok": true,
  "token": "eyJ…",
  "tier": "standard",
  "updates_until": "2027-11-14T00:00:00Z",
  "platforms": ["mac", "windows", "iphone"]
}
```

A code lasts 10 minutes and allows 5 wrong guesses. The 6th burns it, and the buyer asks
for a new one. On success, the newest live purchase for that address is signed into a
token.

Both endpoints answer CORS preflights with `Access-Control-Allow-Origin: *`, so a web view
or your marketing site can call them.

## The token

An Ed25519-signed compact JWT, like a license token, but with **no `exp`**. It never
expires on purpose. Verify it with the same steps as in
[client integration](client-integration.md#verify-the-token), skipping the device and
nonce checks.

| Claim | Meaning |
|-------|---------|
| `v` | token format version |
| `sub` | the purchase |
| `tier` | `standard` or `forever`. Neither ever stops the app |
| `updates_until` | when updates end for `standard`, or `null` |
| `device` | the `device_id` you sent, echoed back. Licencio doesn't store it |
| `iat` | issued at, as an ISO 8601 time (not Unix seconds, unlike license tokens) |

The header carries a `kid` (`a` or `b`) naming which key signed it.

## How addresses match

Addresses are compared in a normalized form: lowercased, trimmed, with any `+tag` removed,
and with dots removed for `gmail.com` and `googlemail.com` only. So `Ada.L+mac@gmail.com`
matches a purchase made as `adal@gmail.com`.

The same rule exists in Ruby (`Purchase.normalize_email`) and in SQL
(`Purchase::NORMALIZED_EMAIL_SQL`), and a test checks they agree. If you change one, change
both, or a buyer who paid won't be able to unlock.

## Key rotation

Unlock tokens never expire and installs may never update, so your app has to trust a
replacement key from day 1. Ship **2** public keys in every build, picked by the token
header's `kid`.

```bash
bin/rails "unlock:generate_backup_key[my-app]"
```

This creates key `b`, stores only its public half, and prints the private half **once**.
Put that in cold storage. It also prints both `(kid, public key)` pairs to embed in your
app. Key `a` is the one already in `eddsa_public_key`, and `eddsa_key_id` says which key
signs today.

To rotate, restore the cold private key into `eddsa_private_key` and set `eddsa_key_id` to
`b`. Tokens already issued keep verifying against `a`, which every install still trusts.

**Do this before your first release.** There's no way to add a second key to installs that
never update.

## Support

With no accounts, the support lookup is how you answer "why can't I unlock?":

```bash
curl -X POST https://YOUR_HOST/v1/support/lookup \
  -H "X-Admin-Token: $SUPPORT_ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"product_slug":"my-app","email":"ada@example.com","resend_code":true}'
```

It returns every purchase for that address (tier, dates, refund, platform) and, with
`resend_code`, emails a fresh code past the 3-per-15-minutes budget. It allows 10 lookups
a minute. With `SUPPORT_ADMIN_TOKEN` unset, it refuses every request.

## App Review

Apple's reviewers can't read a buyer's inbox. Set `REVIEW_UNLOCK_EMAIL` and
`REVIEW_UNLOCK_CODE`, and that one address accepts that fixed code instead of an emailed
one. The address still needs a real purchase. Unset both once review is done.
