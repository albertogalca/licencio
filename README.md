<p align="center">
  <img src="public/icon.svg" alt="Licencio" width="72" height="72">
</p>

<h1 align="center">Licencio</h1>

Self-hostable software-licensing backend. Sell licenses for your apps through
Stripe, and hand every activated device a **cryptographically signed license
token (EdDSA JWT)** it can verify **offline** — no phone-home, no license server
in the hot path.

Built with Rails 8, Postgres, and the Solid stack (Queue/Cache/Cable — all in one
database). No Redis, no external services required beyond Stripe and (optionally)
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
| `POST /api/checkout` | product `slug` + Stripe `price_id` in body | create a Stripe Checkout session for the chosen variant |
| `POST /api/licenses/activate` | `X-Api-Key` | activate a device → `{ jwt, public_key }` |
| `DELETE /api/licenses/deactivate` | `X-Api-Key` | free a device seat |
| `POST /api/licenses/recover` | `X-Api-Key` | email the customer a portal magic link |
| `POST /api/admin/migrations/import` | `Bearer ADMIN_API_KEY` | bulk-import licenses (Lemon Squeezy / Polar) |
| `POST /webhooks/stripe/:product_id` | Stripe signature | fulfill + email purchases (`checkout.session.completed`); revoke on refund (`charge.refunded`). Verified with that Product's `stripe_webhook_secret` |
| `GET /portal` … | session cookie | customer self-serve portal |
| `GET /up`, `/health` | — | health checks |

## Self-hosting

### Quick start (Docker)

Requires Docker with Compose. One physical Postgres, one database, one web
container (Solid Queue runs inside Puma).

```bash
git clone <your-fork> licencio && cd licencio

# 1. Generate a master key + credentials if you don't have them yet.
#    (Keep config/master.key secret and OUT of git — it's already gitignored.)
#    Skip if you already have config/master.key from a Rails credentials:edit.
EDITOR=true bin/rails credentials:edit   # creates config/master.key + credentials.yml.enc

# 2. Configure the environment.
cp env.example .env
#    Put the master key into .env so the container can decrypt credentials:
echo "RAILS_MASTER_KEY=$(cat config/master.key)" >> .env
#    ...then edit .env and fill in Stripe / Loops / admin keys.

# 3. Boot it. The container runs db:prepare (create + migrate) on start.
docker compose up --build
```

The app comes up on `http://localhost` (health check at `/up`). Behind a
TLS-terminating proxy (Coolify, Render, Caddy, Kamal proxy) it enforces HTTPS
automatically (`config.assume_ssl` + `config.force_ssl`).

> **One-click platforms** (Coolify / Render / Hetzner / DigitalOcean App Platform)
> read this repo's `docker-compose.yml` or `Dockerfile` directly. Provide the same
> environment variables through their dashboard and point `DATABASE_URL` at your
> managed Postgres. Because it's a **single database**, any managed Postgres works
> as-is.

### Active Record encryption

`Product#eddsa_private_key`, `Product#loops_api_key`, `Product#stripe_secret_key`,
and `Product#stripe_webhook_secret` are encrypted at rest.
The keys live in Rails credentials under `active_record_encryption`. If you
generated fresh credentials in step 1, add them once:

```bash
bin/rails db:encryption:init          # prints keys
bin/rails credentials:edit            # paste them under `active_record_encryption:`
```

`RAILS_MASTER_KEY` is what unlocks all of this in production — without it the app
can't decrypt credentials or encrypted columns.

## Environment variables

See [`env.example`](env.example) for the full, commented list. The essentials:

| Variable | Required | Purpose |
|----------|----------|---------|
| `RAILS_MASTER_KEY` | ✅ | unlocks credentials + Active Record encryption |
| `DATABASE_URL` | ✅ (auto-set by compose) | Postgres connection (single database) |
| `APP_HOST` | ✅ in prod | host for magic-link / mailer URLs, e.g. `licenses.yourapp.com` |
| `ADMIN_API_KEY` | for imports | Bearer token for `/api/admin/*` |
| `LOOPS_API_KEY_DEFAULT` | for email | fallback Loops key (per-Product key overrides it) |
| `CHECKOUT_SUCCESS_URL` / `CHECKOUT_CANCEL_URL` | for checkout | Stripe redirect targets |

## Creating your first Product

Create an admin login and use the admin UI:

```bash
docker compose exec web bin/rails "admin:create[you@example.com,a-strong-password]"
```

Sign in at `/admin`, then **Products → New**. `slug`, `bundle_identifier`, and
`license_prefix` are set once (baked into license keys); the `api_key` and EdDSA
keypair are generated for you and shown on the product's edit page.

Ship `eddsa_public_key` inside your client app; it's static per Product and safe
to publish. See [`docs/client-integration.md`](docs/client-integration.md) for the
offline verification code (Swift/CryptoKit), and
[`docs/operating-guide.md`](docs/operating-guide.md) for the full field-by-field
walkthrough.

## Connecting Stripe

1. Create a Stripe **Product** and, on the Licencio Product in `/admin`, set its
   `prod_…` id and its `stripe_secret_key` (`sk_…`). Different Licencio Products can
   use different Stripe accounts — the key is stored (encrypted) per Product.
2. Add one **Price** per variant (seat option) on that Stripe Product — e.g.
   `nickname` "3 seats", a one-time amount, and metadata **`seats: 3`**. The
   `seats` value becomes the license's device cap; missing metadata falls back to
   the product's `max_activations_default` (blank there = unlimited seats). Add
   metadata `update_policy: lifetime` to sell a lifetime variant on a versioned
   product. A single-price product is just one Price. Prices are managed entirely
   in Stripe — no price data is stored locally.
3. Add a webhook endpoint → `https://APP_HOST/webhooks/stripe/PRODUCT_ID` (the
   Product's edit page shows the exact URL), event `checkout.session.completed`.
   Paste its signing secret into the Product's `stripe_webhook_secret`.
4. Your app calls `POST /api/checkout` with the Product `slug` and the chosen
   variant's `price_id` to get a Checkout URL. On payment, the webhook fulfills
   the license (idempotent on the Stripe payment id).

## Development

Postgres, Ruby (see `.ruby-version`), then:

```bash
bin/setup            # installs gems, prepares the dev database
bin/rails test       # Minitest suite
bin/dev              # Rails server + Tailwind watcher
```

## Known limitations

- **Refunds revoke server-side, not offline.** A `charge.refunded` webhook flips
  the license to `refunded`, which blocks new device activations. But a token a
  device already holds keeps verifying offline until its `expires_at` (and
  `lifetime` licenses have none). That's inherent to offline verification — if you
  need faster revocation, have the client re-activate periodically so the `403`
  takes effect.

PRs welcome.
