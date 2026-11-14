<p align="center">
  <img src="public/icon.svg" alt="Licencio" width="72" height="72">
</p>

<h1 align="center">Licencio</h1>

Licencio is a self-hosted licensing backend for desktop and mobile apps. You sell through
Stripe, Licencio issues the license key, and each device gets a signed token it checks
**offline**. Your app never has to call home on launch.

The token is an Ed25519-signed JWT. Your app verifies it with a public key you ship inside
the build, so there's no shared secret in the client and nothing to break when your server
is down.

It's a Rails 8 app on one Postgres database. Jobs, cache and websockets all live in that
database (the Solid stack), so there's no Redis. The only outside services are Stripe and,
if you want email, Loops.

## How it works

```
Your website ──buy link──> Stripe Checkout ──webhook──> Licencio ──email──> Buyer
                                                           │
Your app ──POST /api/licenses/activate (license key)───────┘
         <── signed token, verified offline from then on
```

1. A buyer clicks a buy link on your site and pays on Stripe Checkout.
2. Stripe calls Licencio's webhook. Licencio creates the license and emails the key.
3. The buyer pastes the key into your app. The app activates once and gets a token.
4. On every launch the app checks that token offline. Every few days, when it's online, it
   quietly re-activates to refresh it. That refresh is how refunds take effect.

One Licencio instance can sell many apps. Each app is a **Product** with its own Stripe
account, its own signing key, its own API key and its own email setup. Nothing is shared
between Products, so a buyer of one app never sees keys from another.

## What you get

- License keys with device seats, trials, expiry, and per-license update policies
  (lifetime, a year of updates, or locked to a major version).
- Stripe Checkout with Stripe as merchant of record, so Stripe handles sales tax.
- A customer portal with magic-link sign-in. Buyers recover keys, free up devices, renew and
  add seats there without emailing you.
- An admin at `/admin` for products, licenses, customers and devices.
- Optional extras: unlock by email (no keys at all), AppSumo-style deal codes, gift cards,
  bundle-store issuance, and imports from Lemon Squeezy and Polar.

## Docs

Read them in this order. Each one is for a different job.

| Doc | Read it when you want to |
|-----|--------------------------|
| [Self-hosting](docs/self-hosting.md) | get Licencio running, locally or on a server |
| [Operating guide](docs/operating-guide.md) | set up a product, connect Stripe, put buy links on your site, handle refunds |
| [Client integration](docs/client-integration.md) | make your app activate a key and verify the token offline |
| [API reference](docs/api.md) | look up an endpoint, its auth, and its errors |
| [Unlock by email](docs/unlock-by-email.md) | let buyers unlock with a 6-digit code instead of a key |
| [Deal codes](docs/deal-codes.md) | sell on AppSumo or another code-based deal site |
| [Optional features](docs/optional-features.md) | gifts, bundles, seat upgrades, student pricing, regional pricing, App Store |

## Quick start

You need Docker with Compose. The [self-hosting guide](docs/self-hosting.md) explains
each step.

```bash
git clone https://github.com/<you>/licencio && cd licencio
EDITOR=true bin/rails credentials:edit     # creates config/master.key
bin/rails db:encryption:init               # prints 3 keys; paste them into credentials
cp env.example .env
echo "RAILS_MASTER_KEY=$(cat config/master.key)" >> .env
docker compose up --build
docker compose exec web bin/rails "admin:create[you@example.com]"
```

Open `http://localhost/admin`, sign in, and follow the
[operating guide](docs/operating-guide.md) to create your first Product.

## Development

You need Postgres and Ruby (version in `.ruby-version`).

```bash
bin/setup                          # installs gems, prepares the dev database
bin/dev                            # Rails server + Tailwind watcher
PARALLEL_WORKERS=1 bin/rails test  # Minitest suite, single process
```

## Known limitations

- **A refund doesn't lock an offline device straight away.** Tokens carry a 7-day lease.
  An app that's online re-activates in the background and gets the refusal within a day or
  so. A device that stays fully offline keeps working until its lease runs out, up to 7
  days. That's the cost of offline verification. See
  [token lease](docs/client-integration.md#token-lease-and-revocation).
- **The App Store claim isn't configurable yet.** Which App Store product grants which
  license is set in code, not in the admin. See
  [optional features](docs/optional-features.md#app-store-purchases).

## License

MIT, see [`LICENSE`](LICENSE). PRs welcome.
