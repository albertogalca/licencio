<img src="../public/icon.svg" alt="Licencio" width="40" height="40" align="left">

# Self-hosting

This gets Licencio running. Once it's up, the [operating guide](operating-guide.md) takes
you from an empty admin to selling your first license.

Licencio needs 3 things: the app container, one Postgres database, and one secret
(`RAILS_MASTER_KEY`). Background jobs run inside the web process, so there's no separate
worker and no Redis.

## Before you start

You need:

- Docker with Compose, for the server.
- Ruby and Bundler on your own machine, for the 2 one-time key commands below (version in
  `.ruby-version`, then `bundle install`). After setup you won't need them again.
- A Stripe account, to sell.
- A [Loops](https://loops.so) account, if you want Licencio to send email. Optional, but
  without it buyers only get their key from the success page and the recovery form.

## 1. Create your secrets

Licencio keeps its secrets in Rails credentials, encrypted with `config/master.key`. The
same file also encrypts every Product's Stripe keys and signing key in the database.

```bash
git clone https://github.com/<you>/licencio && cd licencio
bundle install

# Creates config/master.key and an empty credentials file.
EDITOR=true bin/rails credentials:edit

# Prints 3 encryption keys.
bin/rails db:encryption:init

# Opens the credentials file. Paste the 3 keys under active_record_encryption:
bin/rails credentials:edit
```

`config/master.key` is gitignored. Keep it out of git and put a copy in your password
manager. **If you lose it, every Stripe key and signing key in the database is unreadable,
and every app you've shipped is pinned to a signing key you can no longer use.**

## 2. Fill in `.env`

```bash
cp env.example .env
echo "RAILS_MASTER_KEY=$(cat config/master.key)" >> .env
```

Then open `.env` and set at least `APP_HOST` and `POSTGRES_PASSWORD`. The full list is
[below](#environment-variables).

## 3. Boot it

```bash
docker compose up --build
```

On boot the container runs `db:prepare`, which creates the database and runs migrations.
The app answers on `http://localhost`, and `http://localhost/up` returns 200 when it's
healthy.

## 4. Create your admin login

There's no signup page. The password is read from a hidden prompt, so it stays out of your
shell history. In zsh, keep the quotes around the brackets.

```bash
docker compose exec web bin/rails "admin:create[you@example.com]"
```

Sign in at `/admin`. Run the same command again to add more admins. From here, go to the
[operating guide](operating-guide.md).

## Deploying to a server

Licencio runs anywhere that runs a Dockerfile: Coolify, Render, Kamal, a plain VPS. On a
platform that builds from the `Dockerfile` alone, set these yourself, because
`docker-compose.yml` is what normally sets them:

| Variable | Value | Why |
|----------|-------|-----|
| `DATABASE_URL` | your Postgres URL | there's no bundled database |
| `SOLID_QUEUE_IN_PUMA` | `true` | without it, no job runs: no emails, no expiry sweep |

Any managed Postgres works, since Licencio uses a single database.

With Compose, `DATABASE_URL` in `.env` is ignored, because `docker-compose.yml` always
points it at the bundled `db` container. To use an external database with Compose, remove
the `db` service and the `DATABASE_URL` line from `docker-compose.yml`.

Put Licencio behind a proxy that terminates TLS (Caddy, Traefik, Coolify's proxy). In
production Licencio assumes every request reached the proxy over HTTPS and redirects plain
HTTP, except the `/up` and `/health` checks.

### Updating

Pull, rebuild, restart. Migrations run on boot.

```bash
git pull && docker compose up --build -d
```

### Backups

Everything lives in the one Postgres database, so a nightly `pg_dump` covers it. Keep
`config/master.key` with the backups (but not in the same place). A dump without the key
can restore licenses but not the encrypted Stripe and signing keys.

Separately, export each Product's signing key to cold storage. That's what keeps your apps
working if the server is ever gone for good. See
[If this server ever goes away](operating-guide.md#8-if-this-server-ever-goes-away).

## Environment variables

[`env.example`](../env.example) has the same list with comments. Nothing Stripe-related
goes here: each Product holds its own Stripe keys, set in `/admin`.

| Variable | Needed | What it does |
|----------|--------|--------------|
| `RAILS_MASTER_KEY` | always | decrypts credentials and every encrypted Product field |
| `APP_HOST` | in production | your public host without `https://`, e.g. `licenses.example.com`. Used in emailed links |
| `DATABASE_URL` | without Compose | Postgres connection string |
| `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB` | with Compose | credentials for the bundled database |
| `SOLID_QUEUE_IN_PUMA` | without Compose | `true` runs background jobs inside the web process |
| `LOOPS_API_KEY_DEFAULT` | for email | Loops key used by any Product that doesn't set its own |
| `ADMIN_API_KEY` | for imports and deal-code revokes | Bearer token for `/api/admin/*`. Generate with `openssl rand -hex 32` |
| `SUPPORT_ADMIN_TOKEN` | for unlock by email | `X-Admin-Token` for `POST /v1/support/lookup`. Unset means the endpoint refuses everyone |
| `SENTRY_DSN` | optional | report errors to your Sentry project |
| `WEB_CONCURRENCY` | optional | Puma workers per container |
| `JOB_CONCURRENCY` | optional | Solid Queue worker processes |
| `RAILS_LOG_LEVEL` | optional | default `info` |
| `WEB_PORT` | optional | host port Compose binds, default `80` |
| `REVIEW_UNLOCK_EMAIL`, `REVIEW_UNLOCK_CODE` | App Review only | one address that unlocks by email with a fixed code. Leave unset otherwise |

Import scripts read a few more (`LS_TOKEN`, `POLAR_TOKEN`, `DRY_RUN`, `OUT`). The doc for
each task names them.

## Troubleshooting

**Emails never arrive.** Check that jobs are running (`SOLID_QUEUE_IN_PUMA=true` outside
Compose), that the Product has a Loops API key or `LOOPS_API_KEY_DEFAULT` is set, and that
the template id for that email is filled in. A blank template id skips that email on
purpose.

**`ActiveRecord::Encryption::Errors::Decryption`.** The running app has a different
`RAILS_MASTER_KEY` from the one that wrote the data, or the encryption keys in credentials
changed.

**Checkout returns 503.** The Product is missing Stripe keys or checkout URLs, or a Stripe
Price has no `seats` metadata and the Product has no default seats. See
[Connect Stripe](operating-guide.md#connect-stripe).
