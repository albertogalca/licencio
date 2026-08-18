<p align="center">
  <img src="public/icon.svg" alt="Licencio" width="72" height="72">
</p>

<h1 align="center">Licencio</h1>

Self-hostable licensing backend for your apps. Sell license keys through Stripe;
each activated device gets a signed key it can check **offline** — no license
server to call every time the app launches.

Under the hood that signed key is an EdDSA (Ed25519) JWT the device verifies with
a public key you ship in the app — so there's no phone-home and no shared secret
in the client. Built on Rails 8 + Postgres with the Solid stack (Queue/Cache/Cable,
all in one database): no Redis, nothing external beyond Stripe and (optionally)
Loops for email.

- **License**: MIT (see [`LICENSE`](LICENSE))
- **Operating guide** (setup → Stripe/Loops → admin → website): [`docs/operating-guide.md`](docs/operating-guide.md)
- **Client integration**: [`docs/client-integration.md`](docs/client-integration.md)

## The Studio Model

One Licencio instance hosts many independent **Products** — one row per app you
sell. Each Product is a self-contained tenant that owns:

- its own **Stripe account** — `stripe_product_id`, `stripe_secret_key`, and
  `stripe_webhook_secret` (the two keys encrypted at rest), so different Products can
  bill through entirely separate Stripe accounts,
- its own **EdDSA signing keypair** (auto-generated; private key encrypted at rest),
- its own **device API key** (`prod_…`, auto-generated),
- its own **Loops** email config (optional per-product API key + templates).

Credentials never cross Products — a customer email for one app never lists keys
from another. That isolation is the "Studio Model": run your whole studio's
catalog from a single deployment.

```
Product ──< License ──< Activation        (a Product owns Licenses; a License owns device seats)
                └─ Customer               (the buyer; passwordless, magic-link portal)
```

- **Product** — a sellable app. Default update policy is `lifetime`, `time_limited`
  (`update_duration_days`), or `versioned` (gated by `current_version`, the latest
  released major version). Sets `max_activations_default` (seats per license).
- **License** — issued on purchase. Has a unique `license_key`, a seat cap
  (`max_activations`), optional `expires_at`. Can carry its own `update_policy`
  (overrides the product's) plus `licensed_version` — so one product can sell both
  lifetime and version-locked (e.g. "v1") licenses at once.
- **Activation** — one device seat (`hardware_id` + `device_name`).
- **Customer** — the buyer. No passwords; signs into the portal via emailed
  magic link.

### Endpoints

| Route | Auth | Purpose |
|-------|------|---------|
| `GET /api/products/:slug/variants` | none | list a product's variants (Stripe prices) for a pricing page |
| `GET /api/products/:slug/stats` | none | product's distinct customer count (for "trusted by N" social proof) |
| `GET /api/checkout?product_slug=…&price_id=…` | none | 302-redirect a plain buy link straight to Stripe Checkout |
| `POST /api/checkout` | product `slug` + Stripe `price_id` in body | create a Stripe Checkout session (Managed Payments) → `{ url }` |
| `POST /api/licenses/activate` | `X-Api-Key` | activate a device → `{ jwt, public_key }` |
| `DELETE /api/licenses/deactivate` | `X-Api-Key` | free a device seat |
| `POST /api/licenses/recover` | `X-Api-Key` | email the customer a portal magic link |
| `POST /api/admin/migrations/import` | `Bearer ADMIN_API_KEY` | bulk-import licenses (Lemon Squeezy / Polar) |
| `POST /v1/unlock/request` | none | email → six-digit code in the buyer's inbox (always `{ ok: true }`) |
| `POST /v1/unlock/verify` | none | code → permanent Ed25519 entitlement token |
| `POST /v1/support/lookup` | `X-Admin-Token: SUPPORT_ADMIN_TOKEN` | what did this address buy, and optionally re-send a code |
| `POST /webhooks/stripe/:product_id` | Stripe signature | fulfill + email purchases (`checkout.session.completed`); revoke on refund (`charge.refunded`). Verified with that Product's `stripe_webhook_secret` |
| `GET /portal` … | session cookie | customer self-serve portal |
| `GET /up`, `/health` | — | health checks |

## Unlock by email (no accounts, no keys)

A second way in, alongside the license-key system — not a replacement. Nothing about
license keys changes, and both work at the same time.

A buyer types their email, gets six digits, types them back, and the app is permanently
unlocked. There is no account, no password, no device limit, and nothing that revokes.
The apps work forever, offline, after one unlock.

1. `POST /v1/unlock/request` → always `{ ok: true }`, at the same speed, whatever the
   answer. Whether the address bought anything is decided in `UnlockCodeJob`, behind the
   queue, so a caller can't learn it by timing the response. Three codes per address per
   fifteen minutes; over budget the answer is still `{ ok: true }` and no mail is sent.
2. `POST /v1/unlock/verify` → a `LoginCode` allows five wrong guesses inside ten minutes;
   the sixth burns it. On success the newest live `Purchase` for that address is signed
   into an entitlement token.

The token is an EdDSA compact JWT with **no `exp`** — permanently valid by design. Its
claims are `{ v, sub, tier, updates_until, device, iat }`. `device` is echoed straight
back from the request and stored nowhere: unlimited devices means there is nothing to
count. `tier` is `standard` (a year of updates) or `forever`; neither ever stops the app
working.

Addresses are matched on a **normalized** form — lowercased, trimmed, `+tag` stripped,
and dots stripped for `gmail.com`/`googlemail.com` only. `Purchase.normalize_email` and
`Purchase::NORMALIZED_EMAIL_SQL` are the same rule in Ruby and in Postgres (an expression
index backs the lookup), and a test asserts the two agree — a disagreement is a customer
who paid and can't unlock.

Purchases are written by the Stripe webhook next to the license it already mints, but
only for prices whose metadata carries a `tier`. A product that doesn't tag its prices is
untouched by all of this.

### Key rotation (kid `a` / `b`)

Clients verify these tokens offline, forever, and may never contact the server again — so
a key can only be rotated if every client already trusts the replacement. Ship **two**
public keys in every build, keyed by the token header's `kid`:

```
rake "unlock:generate_backup_key[cozy]"   # prints the private half ONCE — cold-store it
```

That mints key `b`, stores only its public half (`products.eddsa_backup_public_key`), and
prints both `(kid, public key)` pairs to embed. `products.eddsa_key_id` says which one
signs today — `a`, the key already in `eddsa_public_key`. To rotate, restore the cold
private key into `eddsa_private_key` and set `eddsa_key_id` to `b`; already-issued tokens
keep verifying against `a`, which clients still trust.

Do this **before the first client ships**. Afterwards there is no way to add a second key
to installs that never update.

## Self-hosting

### First-time setup (Docker)

Requires Docker with Compose. One Postgres, one database, one web container
(Solid Queue runs inside Puma). Run these once:

```bash
git clone <your-fork> licencio && cd licencio

# 1. Create your master key + credentials (skip if you already have config/master.key).
#    Keep config/master.key secret and OUT of git — it's already gitignored.
EDITOR=true bin/rails credentials:edit

# 2. Add the Active Record encryption keys. These encrypt each Product's Stripe,
#    Loops, and signing secrets at rest. Generate them, then paste them into your
#    credentials under `active_record_encryption:`.
bin/rails db:encryption:init          # prints keys to copy
bin/rails credentials:edit            # paste them under active_record_encryption:

# 3. Set up the environment file.
cp env.example .env
echo "RAILS_MASTER_KEY=$(cat config/master.key)" >> .env
#    ...then edit .env and fill in the rest (see Environment variables below).

# 4. Boot it. The container runs db:prepare (create + migrate) on start.
docker compose up --build
```

The app comes up on `http://localhost` (health check at `/up`). `RAILS_MASTER_KEY`
is the one thing that unlocks everything in production — without it the app can't
decrypt credentials or take payments.

Behind a TLS-terminating proxy (Coolify, Render, Caddy, Kamal proxy) it enforces
HTTPS automatically.

> **One-click platforms** (Coolify / Render / Hetzner / DigitalOcean App Platform)
> read this repo's `docker-compose.yml` or `Dockerfile` directly. Set the same
> environment variables in their dashboard and point `DATABASE_URL` at your managed
> Postgres — any managed Postgres works, since it's a **single database**.

## Environment variables

See [`env.example`](env.example) for the full, commented list. The essentials:

| Variable | Required | Purpose |
|----------|----------|---------|
| `RAILS_MASTER_KEY` | ✅ | unlocks credentials + Active Record encryption |
| `DATABASE_URL` | ✅ (auto-set by compose) | Postgres connection (single database) |
| `APP_HOST` | ✅ in prod | host for magic-link / mailer URLs, e.g. `licenses.yourapp.com` |
| `ADMIN_API_KEY` | for imports | Bearer token for `/api/admin/*` |
| `SUPPORT_ADMIN_TOKEN` | for unlock support | `X-Admin-Token` for `POST /v1/support/lookup` |
| `LOOPS_API_KEY_DEFAULT` | for email | fallback Loops key (per-Product key overrides it) |

Everything Stripe — including the checkout success/cancel redirect URLs — lives
**per-Product** in `/admin`, not in the environment.

## Creating your first Product

Create an admin login (the password is read from a hidden prompt, so it never
lands in your shell history), then use the admin UI:

```bash
docker compose exec web bin/rails "admin:create[you@example.com]"
```

Sign in at `/admin` and go to **Products → New**. The full field-by-field
walkthrough — connecting Stripe, adding variants, wiring email, and putting
buy/recover links on your website — is the
**[operating guide](docs/operating-guide.md)**. To build the app that verifies
license tokens, see **[client integration](docs/client-integration.md)**.

## Development

Postgres, Ruby (see `.ruby-version`), then:

```bash
bin/setup                        # installs gems, prepares the dev database
PARALLEL_WORKERS=1 bin/rails test # Minitest suite (run single-process)
bin/dev                          # Rails server + Tailwind watcher
```

## Known limitations

- **Refunds revoke on a lease, not instantly.** A `charge.refunded` webhook flips
  the license to `refunded`, which blocks new and renewed activations. Tokens carry
  a short **lease** (`exp`, 7 days), so a device that stays fully offline keeps
  verifying until the lease lapses — inherent to offline verification. An online app
  re-activates in the background before the lease expires and gets the `403` then, so
  connected users revoke near-instantly. See [client integration](docs/client-integration.md#token-lease--revocation).

PRs welcome.
