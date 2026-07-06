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
`Product` columns (`eddsa_private_key`, `loops_api_key`). Without it the app can't
sign tokens or send email.

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

Do this once per deployment (the secret + webhook) and once per product (the
product id). From the [Stripe Dashboard](https://dashboard.stripe.com):

| Value | Where in Stripe | Goes into |
|-------|-----------------|-----------|
| `STRIPE_SECRET_KEY` (`sk_…`) | Developers → API keys | `.env` |
| `stripe_product_id` (`prod_…`) | Product catalog → your product | the **Product** in `/admin` |
| `STRIPE_WEBHOOK_SECRET` (`whsec_…`) | Developers → Webhooks → your endpoint → *Signing secret* | `.env` |
| `CHECKOUT_SUCCESS_URL` / `CHECKOUT_CANCEL_URL` | your own pages | `.env` |

**Two things to get right:**

1. **The Stripe product needs a default price.** Checkout reads
   `Stripe::Product.retrieve(stripe_product_id).default_price` — a product with no
   default price will fail. Set one (one-time price) on the product in Stripe.
2. **Add the webhook endpoint** → `https://YOUR_APP_HOST/webhooks/stripe`, event
   **`checkout.session.completed`**. This is what turns a payment into a license
   (`License.fulfill!` — idempotent on the Stripe payment id, so retries are safe).
   Copy its signing secret into `STRIPE_WEBHOOK_SECRET`.

> Testing? Use `stripe listen --forward-to localhost:3000/webhooks/stripe` and
> paste the `whsec_…` it prints.

---

## 4. Collect your Loops values (email — optional)

Loops sends the **magic-link email** that lets customers into the portal and
lists their license keys. Skip this section if you don't want email yet — buyers
can still be handed keys another way, but the "recover my license" flow won't work
without it.

From the [Loops dashboard](https://app.loops.so):

| Value | Where in Loops | Goes into |
|-------|----------------|-----------|
| API key | Settings → API | `loops_api_key` on the Product, **or** `LOOPS_API_KEY_DEFAULT` in `.env` |
| `loops_magic_link_transactional_id` | Transactional → your email → its id | the Product in `/admin` |
| `sender_email` | the from-address you send as | the Product in `/admin` |

- **Per-product vs default key.** Set `loops_api_key` on a Product to send that
  product's mail from its own Loops account; leave it blank to fall back to
  `LOOPS_API_KEY_DEFAULT`. (This is the Studio Model — one app's email never leaks
  another app's keys.)
- **Your Loops template must accept these data variables**, which the app sends:
  `magic_link_url`, `product_name`, `sender_email`, `license_keys` (the customer's
  keys for *this* product, newline-separated).
- `loops_transactional_id` (a separate field on the form) is **reserved** — the
  column exists for a future purchase-receipt email and isn't sent yet.

---

## 5. Create a Product

Products → **New product** in `/admin`. Fields:

**Set once, locked forever** (they're baked into every license key you issue):

- `slug` — used by your website's checkout call (`product_slug`).
- `bundle_identifier` — your app's id, e.g. `com.example.myapp`.
- `license_prefix` — keys look like `myapp_ab12…`.

**Editable any time:**

- `name`
- `update_policy` — `lifetime`, or `time_limited` (then set `update_duration_days`).
- `max_activations_default` — device seats per license (default 3).
- `trial_days` — optional.
- `stripe_product_id` — from §3.
- `sender_email`, `loops_magic_link_transactional_id`, `loops_api_key` — from §4
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

- **Issue one manually** — Licenses → New. Pick the product, optionally enter a
  `customer_email` (a Customer is created if it doesn't exist), set
  `max_activations`, `status` (`active`), and optional `expires_at`. The license
  key is generated on save.
- **"Activate / deactivate" a license = its `status`.** Edit a license to switch
  between `active`, `inactive`, `expired`, `refunded`. Only `active` licenses can
  activate devices. (Refunds/expiries you handle by setting the status here.)
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

`POST /api/checkout` takes a product `slug`, returns a Stripe URL to redirect to.
No API key needed.

```html
<button id="buy">Buy My App — $49</button>
<script>
  document.getElementById("buy").addEventListener("click", async () => {
    const res = await fetch("https://YOUR_APP_HOST/api/checkout", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ product_slug: "my-app", quantity: 1 }),
    });
    const { url } = await res.json();
    window.location = url; // off to Stripe Checkout
  });
</script>
```

Optional body fields: `quantity` (default 1), `email` (prefills Checkout),
`renew_license_key` (renew an existing license instead of issuing a new one).
On payment, the webhook issues the license — nothing else to do.

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
**`/portal`**, where they see their keys per product and can free a device seat
(deactivate a machine). Just link them to the recovery form from (b); no separate
page to build.

---

### Device activation (in your app, not the website)

When your installed app needs a signed token, it calls
`POST /api/licenses/activate` with the product `X-Api-Key`. That flow — request,
response, and offline verification — is documented in full in
[`client-integration.md`](client-integration.md).
