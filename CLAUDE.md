# Licencio

## Local database — DBngin (NOT Homebrew)

Postgres is managed by **DBngin**, engine named **`licencio`** — PostgreSQL 18.4, port **5432**, user `postgres`, no password. This matches `config/database.yml` as-is.

- Start it in the DBngin app (the "licencio" engine), or from CLI:
  ```
  DIR="$HOME/Library/Application Support/com.tinyapp.DBngin/Engines/postgresql/BAF6B609-717E-4430-9328-D60C9A323720"
  /Users/Shared/DBngin/postgresql/18.4_arm/bin/pg_ctl -D "$DIR" -l "$DIR/postgres_out.log" -w start
  ```
- Only one DBngin engine can bind 5432 at a time — make sure the `licencio` engine (not another project's) is the running one before `rails db:*` / `rails test`.
- **Do not** `brew services start postgresql` — it fights DBngin for port 5432.

## Encryption

`Product#loops_api_key`, `Product#eddsa_private_key`, `Product#stripe_secret_key`, and `Product#stripe_webhook_secret` use Active Record `encrypts`. Keys live in Rails credentials under `active_record_encryption`. Test env sets `config.active_record.encryption.encrypt_fixtures = true` so encrypted columns round-trip through fixtures.

Stripe is per-Product (Studio Model) — no ENV fallback. Each Stripe call passes the product's own `stripe_secret_key` explicitly (`Product#stripe_opts`); there is no global `Stripe.api_key` (the initializer was removed). Inbound webhooks are addressed per product at `/webhooks/stripe/:product_id` and verified with that product's `stripe_webhook_secret`.

## Affiliate program

Global affiliates (one `Affiliate`, one `code`, one rate, spanning all products). A `?ref=CODE` link on a
marketing page is captured by a 60-day cookie on that site, appended to `/api/checkout`, and rides through
the Stripe session `metadata[:affiliate_id]`. On `checkout.session.completed`, commission is **frozen at
sale time** onto `payments.commission_cents` — computed off `amount_subtotal` (pre-VAT, since Managed
Payments' `amount_total` includes tax we never receive), never recomputed from the affiliate's current rate.
Renewals never credit.

- **Payouts are a manual ledger** (`Payout` rows), because `managed_payments: { enabled: true }` (Stripe as
  Merchant of Record) is incompatible with Stripe Connect — no transfers/application fees. Owed =
  `payments.payable.sum(:commission_cents) − payouts.sum(:amount_cents)`. `Payment.payable` clears a 30-day
  refund hold and excludes refunded licenses. Global Payouts (v2 preview) is the future automation path.
- **Self-serve** via magic link, mirroring the `Portal::*` pattern: `AffiliateToken` ≈ `PortalToken`,
  `Affiliate::*` controllers ≈ `Portal::*`. Signup → admin approval (`Affiliate#approve!`) → magic-link email.
- Affiliate emails ship through **one** product's Loops config: `Product.affiliate_mailer` = first product
  with `affiliate_transactional_id` set. Set `affiliate_landing_url` per product for the dashboard's links.

## Conventions

- UUID primary keys everywhere (`config.generators` → `primary_key_type: :uuid`, `gen_random_uuid()` default).
- Enums stored as strings, not integers.
- Default test suite is Minitest (`bin/rails test`).
