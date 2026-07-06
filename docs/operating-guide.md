# Operating guide — running your license store

This is the day-to-day guide for **operators**: set the app up, collect the
values Stripe and Loops give you, create products and licenses in the admin UI,
and wire the buy/recover flows into your website.

- New to the project? Read the [README](../README.md) first (self-hosting, the
  Studio Model, environment variables).
- Building the **client app** that verifies license tokens? See
  [`client-integration.md`](client-integration.md).

Three audiences, three doors — keep them straight:

| Who | Where | Auth |
|-----|-------|------|
| **You (operator)** | `/admin` | email + password |
| **Your customers** | `/portal` + your website | magic-link email |
| **Your app on a device** | `/api/licenses/*` | product `X-Api-Key` |

---

## 1. Prerequisites

The app is running (see the README's [Quick start](../README.md#quick-start-docker))
and `RAILS_MASTER_KEY` is set — it unlocks Rails credentials **and** the encrypted
`Product` columns (`eddsa_private_key`, `loops_api_key`, `stripe_secret_key`,
`stripe_webhook_secret`). Without it the app can't sign tokens, take payments, or
send email.

---

## 2. Create your admin login

There's no signup page — admins are created from the CLI:

```bash
# Docker (quote the brackets in zsh):
docker compose exec web bin/rails "admin:create[you@example.com,a-strong-password]"

# Local dev:
bin/rails "admin:create[you@example.com,a-strong-password]"
```

Then sign in at **`/admin`** (redirects to the login form). You land on the
Products list. Run the rake task again to add more admins.

---

## 3. Collect your Stripe values

Every Product runs on its **own Stripe account** (the Studio Model). All three
Stripe values live on the **Product** in `/admin` — nothing Stripe-secret goes in
`.env`. From the [Stripe Dashboard](https://dashboard.stripe.com):

| Value | Where in Stripe | Goes into |
|-------|-----------------|-----------|
| `stripe_product_id` (`prod_…`) | Product catalog → your product | the **Product** in `/admin` |
| `stripe_secret_key` (`sk_…`) | Developers → API keys | the **Product** in `/admin` (encrypted) |
| `stripe_webhook_secret` (`whsec_…`) | Developers → Webhooks → your endpoint → *Signing secret* | the **Product** in `/admin` (encrypted) |
| `CHECKOUT_SUCCESS_URL` / `CHECKOUT_CANCEL_URL` | your own pages | `.env` |

- **One account per Product.** Each Product carries its own `stripe_secret_key`, so
  one deployment can sell different apps through separate Stripe accounts — a variant
  list, checkout, or webhook for one Product never touches another's keys.

**Two things to get right:**

1. **The Stripe product needs a Price per variant.** Add one **Price** to the
   Stripe product for each seat option — set a `nickname` (e.g. "2 seats"), a
   one-time amount, and metadata **`seats`** (e.g. `2`). That `seats` value becomes
   the license's device cap; if it's missing, checkout falls back to the product's
   `max_activations_default` — and if that's blank too, the license gets **unlimited
   seats**. Prices are pure Stripe config — nothing is stored in the app, so you can
   add, rename, or reprice variants any time. Non-linear pricing works out of the box
   (2 seats need not cost 2×). A single-price product is just one Price. Your
   website's buy button passes the chosen variant's `price_id` to `POST /api/checkout`
   (see §5).
   - **Selling a lifetime option on a `versioned` product?** Add price metadata
     **`update_policy`** = `lifetime` on that Price. Licenses bought through it get a
     per-license `lifetime` override (always update-eligible); prices without it
     inherit the product's default policy. This is how one product sells, e.g., a
     "v1" and a "lifetime" variant at the same price.
2. **Add the webhook endpoint** → `https://YOUR_APP_HOST/webhooks/stripe/PRODUCT_ID`
   (the Product's edit page shows the exact URL), events
   **`checkout.session.completed`** (turns a payment into a license — idempotent on
   the Stripe payment id, so retries are safe — and emails the buyer their key) and
   **`charge.refunded`** (flips the matching license to `refunded`, which blocks
   further device activations). Paste its signing secret into the Product's
   `stripe_webhook_secret`.

> Testing? Use `stripe listen --forward-to localhost:3000/webhooks/stripe/PRODUCT_ID`
> and paste the `whsec_…` it prints into that Product's `stripe_webhook_secret`.

---

## 4. Collect your Loops values (email — optional)

Loops sends **one** transactional email that doubles as purchase delivery and portal
access: the customer's keys for this product **plus** a product-scoped sign-in link.
It fires automatically when a purchase completes, and again whenever a customer uses
the "recover my license" flow. Skip this section if you don't want email yet — buyers
can still be handed keys another way, but automatic delivery and recovery won't work
without it.

From the [Loops dashboard](https://app.loops.so):

| Value | Where in Loops | Goes into |
|-------|----------------|-----------|
| API key | Settings → API | `loops_api_key` on the Product, **or** `LOOPS_API_KEY_DEFAULT` in `.env` |
| `loops_transactional_id` | Transactional → your email → its id | the Product in `/admin` |
| `sender_email` | the from-address you send as | the Product in `/admin` |

- **Per-product vs default key.** Set `loops_api_key` on a Product to send that
  product's mail from its own Loops account; leave it blank to fall back to
  `LOOPS_API_KEY_DEFAULT`. (This is the Studio Model — one app's email never leaks
  another app's keys.)
- **Your template must accept the data variables the app sends:** `license_keys`
  (the customer's keys for *this* product, newline-separated), `magic_link_url`
  (a single-use, product-scoped portal sign-in link), `product_name`, `sender_email`.
- **Delivery is best-effort on config.** If a Product has no `loops_transactional_id`
  set, purchases still fulfill — the buyer just isn't emailed and reaches their key
  via the recover flow. Set the id to turn delivery on.

---

## 5. Create a Product

Products → **New product** in `/admin`. Fields:

**Set once, locked forever** (they're baked into every license key you issue):

- `slug` — used by your website's checkout call (`product_slug`).
- `bundle_identifier` — your app's id, e.g. `com.example.myapp`.
- `license_prefix` — keys look like `myapp_ab12…`.

**Editable any time:**

- `name`
- `update_policy` — the product **default**: `lifetime`, `time_limited` (then set
  `update_duration_days`), or `versioned` (then set `current_version`). Individual
  licenses can override this — see §6.
- `current_version` — for `versioned` products, the latest released major version
  (starts at 1). Bump it to 2 when you ship v2: every v1 license stops being update
  eligible until it's upgraded.
- `max_activations_default` — fallback device seats per license, used when a
  purchased variant's Stripe price has no `seats` metadata. Leave it **blank for
  unlimited** seats (shown as ∞).
- `trial_days` — optional.
- `stripe_product_id` — from §3. Once set, the edit page shows a **read-only list of
  the product's variants** (each Stripe Price — nickname · seats · amount), pulled
  live from Stripe. Manage the prices themselves in Stripe, not here.
- `stripe_secret_key`, `stripe_webhook_secret` — from §3; this product's Stripe
  account. Required to load variants and take payments. Editing is blank-to-keep
  (leave blank to keep the current value). The edit page prints this product's
  webhook URL to register in Stripe.
- `sender_email`, `loops_transactional_id`, `loops_api_key` — from §4
  (leave the key blank to keep the current one / use the default).

**Auto-generated — copy these from the product's edit page:**

- `api_key` (`prod_…`) — your app sends it as the `X-Api-Key` header. Secret.
- `eddsa_public_key` — **embed this in your client app** to verify tokens offline.
  Static per product and safe to publish. See
  [`client-integration.md`](client-integration.md).

---

## 6. Issue and manage licenses

**Most licenses create themselves:** when a customer pays, the Stripe webhook
fulfills the order and issues the license automatically. You only touch the
Licenses screen for manual grants (support, comps, testing) and status changes.

- **Find a license** — the Licenses screen has a search box (matches license key,
  customer email/name, product name, or status) alongside the **All products** /
  **All statuses** filters; combine them freely. The Licenses, Customers, and
  Activations lists paginate at 50 rows per page.
- **Issue one manually** — Licenses → New. Pick the product, optionally enter a
  `customer_email` (a Customer is created if it doesn't exist), set
  `max_activations` (leave blank for unlimited seats), `status` (`active`), and
  optional `expires_at`. The license key is generated on save.
- **Update policy per license** — leave "Update policy" blank to inherit the
  product's, or override it on this one license (`lifetime` / `time_limited` /
  `versioned`). This is how one product sells both kinds at once: e.g. a "lifetime"
  license and a `versioned` license with **Version** = 1 for the same app, same price.
  A `versioned` license stays update eligible while the product's `current_version`
  is ≤ its Version, and stops when you ship a higher major version.
- **Grant a v2 upgrade** — edit the customer's `versioned` license and bump its
  **Version** (1 → 2). They become eligible for v2 updates again; leaving it at 1
  keeps them on v1.
- **"Activate / deactivate" a license = its `status`.** Edit a license to switch
  between `active`, `inactive`, `expired`, `refunded`. Only `active` licenses can
  activate devices. A Stripe refund (`charge.refunded`) flips the status to
  `refunded` automatically; set any of these by hand for manual revocations or
  comps. Note: blocking `status` only stops *new* device activations — a token a
  device already holds keeps verifying offline until its `expires_at` (see the
  README's "Known limitations").
- **Device seats** (which machines are using a license) are managed by the app via
  the API, or by the customer in the portal — not from the admin. **Activations**
  is a read-only log of every device seat.
- **Customers** is read-only: search by email, open one to see its licenses and
  activations.

---

## 7. Add license flows to your website

Three things your marketing site links to. All framework-agnostic — plain HTML +
`fetch`. Replace `YOUR_APP_HOST` with your Licencio host.

### a) Buy button → Stripe Checkout

`POST /api/checkout` takes a product `slug` and a variant `price_id` (the Stripe
`price_…` for the seat option being bought), returns a Stripe URL to redirect to.
No API key needed. Hardcode each variant's `price_id` on your site (copy them from
the Stripe product), or fetch them at page load with
`GET /api/products/:slug/variants` — it returns
`{ variants: [{ price_id, name, amount_cents, seats }, …] }`, cheapest first, so you
can render a pricing table without duplicating amounts in your site code.

```html
<button id="buy" data-price="price_123">Buy My App — 2 seats, $28.78</button>
<script>
  document.getElementById("buy").addEventListener("click", async (e) => {
    const res = await fetch("https://YOUR_APP_HOST/api/checkout", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ product_slug: "my-app", price_id: e.target.dataset.price }),
    });
    const { url } = await res.json();
    window.location = url; // off to Stripe Checkout
  });
</script>
```

`product_slug` and `price_id` are required (the price must belong to the product's
Stripe product, else 404). Optional body fields: `email` (prefills Checkout),
`renew_license_key` (renew an existing license instead of issuing a new one — pass
the same variant's `price_id`). Renewal only applies when the key belongs to the
paying customer; a key from someone else just issues them a fresh license instead.
Seat count comes from the price's `seats` metadata. On payment, the webhook issues
the license — nothing else to do.

### b) "Recover my license" link

Sends the customer an email with their keys and a sign-in link. Two ways:

**Simplest — link to the built-in form** (no code, email is pre-scoped to the product):

```html
<a href="https://YOUR_APP_HOST/portal/recoveries/new?product=my-app">
  Lost your license? Recover it
</a>
```

**Or host your own form** and POST to the API (needs the product API key, so do
this **server-side** — never ship `prod_…` to the browser):

```
POST https://YOUR_APP_HOST/api/licenses/recover
X-Api-Key: prod_xxxxxxxxxxxxxxxx
Content-Type: application/json

{ "email": "buyer@example.com" }
```

Always returns `200` (it won't reveal whether the email exists).

### c) "Manage my licenses" link

Same door as recovery — the emailed magic link drops the customer into
**`/portal`**, **scoped to the product the link came from** (a Cozy link never shows
another app's licenses), where they see that product's keys and can free a device
seat (deactivate a machine). Just link them to the recovery form from (b); no
separate page to build.

---

### Device activation (in your app, not the website)

When your installed app needs a signed token, it calls
`POST /api/licenses/activate` with the product `X-Api-Key`. That flow — request,
response, and offline verification — is documented in full in
[`client-integration.md`](client-integration.md).

---

## 8. Migrating from another store

Moving an existing product (Gumroad, Lemon Squeezy, Polar, …) onto Licencio?
Import your past customers as licenses so their apps keep working — **preserve the
original key strings** and each buyer re-validates against Licencio with the key
they already have.

- **Import endpoint** — `POST /admin/migrations/import` (admin-only) takes CSV or
  JSON rows and a `source` (`lemon_squeezy` or `polar`). Each row maps to a license:
  `product_slug`, `license_key`, optional `email`/`name` (blank email = an unclaimed
  license the buyer claims later), `status`, `max_activations` (blank inherits the
  product default — leave the product's `max_activations_default` blank for
  unlimited), `expires_at`, and per-license `update_policy` / `licensed_version`
  (so versioned buyers get a version snapshot and lifetime buyers an override).
  Re-runnable: rows whose `license_key` already exists are skipped.
- **Polar** exposes keys only through its API (no CSV), so pull them with an
  Organization Access Token — see `lib/tasks/polar.rake` for a worked example that
  maps each Polar product's license-keys benefit to a policy.
- **Old "unlimited" sentinels** — a prior Lemon Squeezy import used `999` to mean
  unlimited; `bin/rails licenses:normalize_unlimited` converts those to real
  unlimited (nil) seats.
