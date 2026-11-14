# Licencio

## This repo is public

Licencio is open source. Everything committed here (code, comments, tests, fixtures, docs, commit messages, PR text) is readable by anyone. Never write anything that points at the owner's own products or business:

- No names of the owner's own products, projects or studio, no real bundle ids, personal domains, or sibling repo paths. The list of names lives in `CLAUDE.local.md` (untracked). Read it before writing.
- No production facts: hosts, customer emails or counts, sales numbers, traffic anecdotes, Stripe/Apple ids, prices.
- Use neutral placeholders instead: `my-app`, `acme`, `com.example.myapp`, `buyer@example.com`, `YOUR_HOST`.
- Product-specific behaviour belongs in Product columns or config set at runtime, never hardcoded in code keyed on a real product.
- Before committing, run the grep in `CLAUDE.local.md` over `git diff --cached`. It must print nothing.

Private runbooks (like `LAUNCH.md`) and `CLAUDE.local.md` stay untracked.

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

## Conventions

- UUID primary keys everywhere (`config.generators` → `primary_key_type: :uuid`, `gen_random_uuid()` default).
- Enums stored as strings, not integers.
- Default test suite is Minitest (`bin/rails test`).
