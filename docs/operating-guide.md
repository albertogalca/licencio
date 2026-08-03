<img src="../public/icon.svg" alt="Licencio" width="40" height="40" align="left">

# Operating guide — running your license store

This is the hands-on guide for **operators**. It walks you through everything in
order: create your admin login, set up a product to sell, put buy/recover links
on your website, and manage licenses day to day.

New here? Read the [README](../README.md) first for what Licencio is and how to
self-host it. Building the **app** that verifies license tokens? That's a
separate job — see [`client-integration.md`](client-integration.md).

**Three audiences, three doors:**

| Who | Where | How they sign in |
|-----|-------|------------------|
| **You (operator)** | `/admin` | email + password |
| **Your customers** | `/portal` (via your website) | magic link by email |
| **Your affiliates** (optional) | `/affiliate` (self-signup) | magic link by email |
| **Your app, on a device** | `/api/licenses/*` | product `X-Api-Key` |

Before you start, make sure the app is running and `RAILS_MASTER_KEY` is set (see
the README) — without it the app can't sign tokens, take payments, or send email.

---

## 1. Create your admin login

There's no signup page. Create the first admin from the command line. The
password is typed at a hidden prompt, so it never ends up in your shell history:

```bash
# Docker (quote the brackets in zsh):
docker compose exec web bin/rails "admin:create[you@example.com]"

# Local dev:
bin/rails "admin:create[you@example.com]"
# → Password: (typed hidden)
```

Now sign in at **`/admin`**. You land on the Products list. Run the same command
again any time to add more admins.

---

## 2. Set up a product to sell

A **Product** is one app you sell. Everything a product needs — its Stripe
account, email settings, and signing key — lives on that product, so a single
Licencio instance can run many apps that never share credentials. Set that up
once and you won't think about it again.

Go to **Products → New product** and fill it in. The fields fall into three
groups.

### Set once — these get baked into every license key

| Field | What it is |
|-------|------------|
| `slug` | short id your website uses at checkout, e.g. `my-app` |
| `bundle_identifier` | your app's id, e.g. `com.example.myapp` |
| `license_prefix` | keys will look like `myapp_ab12…` |

### Connect Stripe

Every product bills through **its own Stripe account** — you paste the Stripe
values onto the product here, nothing Stripe-related goes in `.env`. Grab these
from the [Stripe Dashboard](https://dashboard.stripe.com):

| Field | Where in Stripe |
|-------|-----------------|
| `stripe_product_id` (`prod_…`) | Product catalog → your product |
| `stripe_secret_key` (`sk_…`) | Developers → API keys |
| `stripe_webhook_secret` (`whsec_…`) | Developers → Webhooks → your endpoint → *Signing secret* |
| `checkout_success_url` / `checkout_cancel_url` | your own "thanks" / "cancelled" pages |

Two more steps in Stripe:

1. **Add a Price for each option you sell.** On the Stripe product, add one Price
   per seat option — give it a nickname ("2 seats"), a one-time amount, and a
   metadata field **`seats`**: a number (e.g. `2`) for a device cap, or
   **`unlimited`** (or `0`) for a license that covers every device. These Prices
   are your **variants** (more on selling them in §4). Unlimited must be declared
   explicitly — if a Price has no `seats` **and** the product has no
   `max_activations_default`, checkout is **refused** (a `503`), so you never ship
   an uncapped license by accident. Prices live entirely in Stripe — add, rename,
   or reprice them any time, and non-linear pricing is fine (2 seats needn't cost 2×).

2. **Register the webhook.** In Stripe, add an endpoint at
   `https://YOUR_APP_HOST/webhooks/stripe/PRODUCT_ID` (the product's edit page
   shows the exact URL), subscribed to **`checkout.session.completed`** and
   **`charge.refunded`**. Paste its signing secret into `stripe_webhook_secret`.
   This is what turns a payment into a license and a refund into a revocation —
   see §6.

   > **Testing locally?** Run
   > `stripe listen --forward-to localhost:3000/webhooks/stripe/PRODUCT_ID` and
   > paste the `whsec_…` it prints into `stripe_webhook_secret`.

`checkout_success_url` and `checkout_cancel_url` are **required** once
`stripe_product_id` is set — checkout won't start (and the form won't save)
without them.

### Set the rest

| Field | What it does |
|-------|--------------|
| `name` | display name |
| `update_policy` | the product's default policy — see [Update policies](#update-policies-read-this-once) |
| `current_version` | for `versioned` products, the latest major version (starts at 1) |
| `max_activations_default` | fallback device cap when a Price has no `seats` metadata. A Price with neither is rejected at checkout — set `seats = unlimited` on the Price for an uncapped license |
| `trial_days` | optional free-trial length |

### Branding (optional)

The pages your customers see — license recovery, sign-in and their license
dashboard — can carry your product's look instead of Licencio's defaults.

| Field | What it does |
|-------|--------------|
| `logo_url` | shown above the form, rendered 32px tall (SVG or a 2x PNG) |
| `accent_color` | hex, e.g. `#2563eb`. Buttons, links, focus rings and highlights |
| `background_color` | hex. The page background behind the card |

Leave any of them blank to keep the default. Only the accent needs setting — the
lighter and darker shades are mixed from it. Colours must be hex and the logo
must be an `http(s)` URL; anything else is rejected on save, because both are
rendered into the page.

Branding follows the product the visitor arrived for: the recovery page reads
`?product=<slug>`, and once someone is signed in the portal is already scoped to
the product their magic link came from. Affiliate pages stay unbranded — one
affiliate spans every product.

Once you save with Stripe keys set, the edit page shows a **live, read-only list
of your variants** (each Stripe Price · nickname · seats · amount) and this
product's webhook URL.

**Two values are generated for you — copy them from the edit page:**

- `api_key` (`prod_…`) — your app sends this as the `X-Api-Key` header. Keep it
  secret.
- `eddsa_public_key` — **embed this in your app** to verify tokens offline. It's
  static per product and safe to publish. See
  [`client-integration.md`](client-integration.md).

### Email delivery (Loops — optional)

Licencio sends transactional email through **Loops** — one template per moment.
Every template is **optional**: leave its id blank and that one email is skipped
(purchases still fulfill; buyers can always reach their key through the recover
flow). Each is a separate field on the product.

| When it fires | Product field (Loops template id) | Variables the template receives |
|---------------|-----------------------------------|---------------------------------|
| **Purchase / renewal** — receipt with the bought key | `purchase_transactional_id` | `product_name`, `license_keys` (just the purchased key), `amount`, `magic_link_url`, `sender_email` |
| **Recover / manual grant** — portal access, all of the customer's keys | `loops_transactional_id` | `product_name`, `license_keys` (all, newline-separated), `magic_link_url`, `sender_email` |
| **Full refund** — cancellation notice | `refund_transactional_id` | `product_name`, `license_keys`, `magic_link_url`, `sender_email` |
| **~7 days before a `time_limited` license expires** (daily sweep) | `expiry_reminder_transactional_id` | `product_name`, `license_keys` (that key), `expires_at` (pre-formatted, "August 3, 2026"), `renew_url`, `magic_link_url`, `sender_email` |

Ready-to-paste HTML for the receipt, refund, and expiry emails lives in
[`docs/email-templates/`](email-templates/) — upload each in Loops and copy its id
into the matching field. Loops merge tags look like `{DATA_VARIABLE:product_name}`.
Every `magic_link_url` carries the product and is reusable for 30 minutes (see §3).

Auth and from-address (shared by all templates):

| Field | Where in Loops |
|-------|----------------|
| `loops_api_key` | Settings → API (or leave blank to use `LOOPS_API_KEY_DEFAULT` from `.env`) |
| `sender_email` | the from-address you send as |

**Contact sync.** On purchase the buyer is also added to your Loops audience as a
contact (`source: "Stripe"`, subscribed); a full refund unsubscribes them. This
reuses `loops_api_key` — no extra setup — and is how you segment buyers for
broadcasts.

---

## Update policies (read this once)

Every license is update-eligible or not, decided by its **update policy**. A
product has a default policy; any single license can override it. This is the one
concept worth understanding up front — everything else refers back here.

| Policy | The license is update-eligible… | Set up with |
|--------|--------------------------------|-------------|
| `lifetime` | always | nothing else |
| `time_limited` | for a fixed window after purchase | `update_duration_days` on the product |
| `versioned` | while the product's `current_version` ≤ the license's `Version` | `current_version` on the product |

**Selling more than one policy for the same app?** Two ways to override per
license:

- **At checkout** — add metadata `update_policy` (e.g. `lifetime`) to a Stripe
  Price. Licenses bought through it get that override; other Prices inherit the
  product default. This is how you sell, say, a "v1" and a "lifetime" variant side
  by side.
- **By hand** — set a license's Update policy in `/admin` (blank = inherit the
  product's).

**Shipping a new major version?** Bump the product's `current_version` (1 → 2).
Every `versioned` license still on `Version` 1 stops being update-eligible until
you raise its `Version` too. That's how a paid v2 upgrade works: edit the
customer's license, bump `Version` 1 → 2, they're eligible again.

The app enforces this — `update_eligible` rides along in every signed token (see
[`client-integration.md`](client-integration.md)).

---

## 3. How customers use the portal

Customers never get a password. They sign in through a **magic link** emailed to
them — from a purchase, or from the "recover my license" flow (§4). The link
drops them into **`/portal`**, scoped to the one product it came from (a link for
one app never shows another app's licenses).

In the portal a customer can:

- **See their licenses** for that product — the keys, the expiry date (for
  `time_limited` licenses), and every device using them.
- **Free up a seat** by deactivating a device (frees a machine so they can
  install elsewhere).
- **Renew a license** — when a `time_limited` license is expired or within 30 days
  of expiring, a **Renew** button appears (with a price picker) that sends them
  straight to Stripe Checkout, tagged to extend *that* license. A freshly renewed
  license, far from expiry, hides the button. (Renewal needs the product's Stripe
  keys and checkout URLs, same as a purchase.)

Sign-in links are per product, valid 30 minutes and **reusable within that
window** — reopening the same link works until it expires, so an emailed link
isn't a one-shot. Someone who owns two of your apps holds one live link for each;
requesting one never cancels the other. An expired link bounces to the recover
form, pre-scoped to the right product. You don't build any of this; you just link
customers to the recover form (§4).

---

## 4. Sell from your own landing page

Three things to add to your marketing site. All plain HTML + `fetch`, no
framework needed. Replace `YOUR_APP_HOST` with your Licencio host.

### a) Buy button → Stripe Checkout

A **variant** is a Stripe Price — one seat/pricing option. To sell one, POST its
`price_id` to `/api/checkout` and redirect the browser to the URL you get back.
No API key needed.

Hardcode each `price_id` on your site (copy from Stripe), or fetch them at page
load so you don't duplicate prices in two places:

```
GET https://YOUR_APP_HOST/api/products/my-app/variants
→ { "variants": [ { "price_id": "price_…", "name": "Pro", "amount_cents": 4900, "seats": 3 }, … ] }
```

(cheapest first — render it straight into a pricing table). Then the buy button:

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

**Simplest option — a plain link.** `GET /api/checkout` builds the same session
but **302-redirects straight to Stripe**, so a static site needs no JavaScript at
all — just an `<a>`:

```html
<a href="https://YOUR_APP_HOST/api/checkout?product_slug=my-app&price_id=price_123">
  Buy My App
</a>
```

Both routes run Checkout through **Stripe Managed Payments** — Stripe is the
merchant of record, so it calculates, collects, and remits tax (no registrations
on your end) — and the Checkout page shows a coupon field. Enable Managed Payments
on your Stripe account first, or session creation errors.

`product_slug` and `price_id` are required (the price must belong to the
product's Stripe product, or you get a 404). Optional fields (body for POST,
query string for GET):

- `email` — prefills the Checkout form.
- `renew_license_key` — renews an existing license instead of issuing a new one
  (pass the same variant's `price_id`). Only works when the key belongs to the
  paying customer; a stranger's key just gets them a fresh license.

On payment, the webhook issues the license and emails the buyer. Nothing else to
do.

### b) "Recover my license" link

Sends the customer their keys and a portal sign-in link. Simplest option — link
to the built-in form (no code; the product is pre-filled from the URL):

```html
<a href="https://YOUR_APP_HOST/portal/recoveries/new?product=my-app">
  Lost your license? Recover it
</a>
```

Prefer your own form? POST to the API instead — but this needs the product API
key, so do it **server-side** and never ship `prod_…` to the browser:

```
POST https://YOUR_APP_HOST/api/licenses/recover
X-Api-Key: prod_xxxxxxxxxxxxxxxx
Content-Type: application/json

{ "email": "buyer@example.com" }
```

Always returns `200` — it won't reveal whether the email exists.

> On the built-in form, a customer who arrives without a product in the URL can
> type the product's **name or slug** (any case) — "Cozy" or "cozy" both work.

### c) "Manage my licenses" link

Same door as recovery: the emailed magic link is what drops them into the portal
(§3). Just reuse the recover link from (b) — there's no separate page to build.

### d) Referral tracking (optional)

Running the affiliate program (§8)? Add the one cookie snippet from
[§8](#8-affiliate-program-optional) to your marketing site so a `?ref=CODE` visit
is remembered for 60 days and appended to the buy links above. Nothing else on the
buy/recover links changes.

---

## 5. Device activation (in your app, not the website)

When your installed app needs a signed token, it calls `POST /api/licenses/activate`
with the product `X-Api-Key`. That whole flow — request, response, and offline
verification — lives in [`client-integration.md`](client-integration.md).

A client that can't safely hold the API key (an App Store binary is a zip file) uses
the public `POST /api/licenses/validate` instead: key in, entitlement out, no signed
token and no seat consumed. Same doc, "Entitlement check for clients that can't hold
the API key".

---

## 6. Manage licenses

**Most licenses create themselves.** When a customer pays, the Stripe webhook
fulfills the order and issues the license automatically (idempotent on the Stripe
payment id, so retries are safe). You only open the Licenses screen for the
occasional manual grant or status change.

- **Find a license** — the search box matches license key, customer email/name,
  product, or status; combine it with the product/status filters. Lists paginate
  at 50 rows.
- **Issue one by hand** (comps, support, testing) — Licenses → New. Pick the
  product, optionally enter a `customer_email` (a Customer is created if new), set
  `max_activations` (blank = unlimited), `status`, and optional `expires_at`. The
  key is generated on save. If you attach a customer and Loops is set up, they're
  emailed their key + portal link automatically, just like a purchase.
- **Update policy per license** — leave blank to inherit the product's, or
  override it here. See [Update policies](#update-policies-read-this-once).
- **Activate / deactivate = the license `status`.** Edit a license to switch
  between `active`, `inactive`, `expired`, `refunded`. Only `active` licenses can
  activate new devices. A full Stripe refund (`charge.refunded`) flips a license
  to `refunded` for you — and, if configured, emails the buyer a cancellation
  notice and unsubscribes them from Loops (unless they still hold another active
  license for that product). Set the others by hand for manual revocations. **Heads
  up:** changing status blocks *new and renewed* activations, but a token a device
  already holds keeps verifying offline until its lease (`exp`) lapses — up to
  7 days. An online app re-activates in the background and revokes near-instantly;
  a fully-offline device lingers until the lease expires (see the README's "Known
  limitations").
- **Devices (seats)** are managed by your app (via the API) or by the customer
  (in the portal), not from admin. The **Activations** screen is a read-only log.
- **Customers** is read-only — search by email, open one to see their licenses
  and activations.

---

## 7. Migrating from another store

Moving an existing product (Gumroad, Lemon Squeezy, Polar, …) onto Licencio?
Import your past buyers as licenses so their apps keep working — **keep the
original key strings**, and each buyer re-validates against Licencio with the key
they already have.

- **Import endpoint** — `POST /api/admin/migrations/import` (admin-only, uses
  `ADMIN_API_KEY`) takes CSV or JSON rows plus a `source` (`lemon_squeezy` or
  `polar`). Each row maps to a license: `product_slug`, `license_key`, optional
  `email`/`name` (blank email = an unclaimed license the buyer claims later),
  `status`, `max_activations` (blank inherits the product default), `expires_at`,
  and per-license `update_policy` / `licensed_version`. Re-runnable — rows whose
  `license_key` already exists are skipped.
- **Polar** exposes keys only through its API (no CSV export), so pull them with
  an Organization Access Token — `lib/tasks/polar.rake` has a worked example.
- **Lemon Squeezy** can be imported the same API-driven way instead of by CSV:
  `lib/tasks/lemon_squeezy.rake` pulls keys with an LS API token
  (`LS_TOKEN=… bin/rails lemon_squeezy:import`, re-runnable — only new keys import).
  `lemon_squeezy:verify_seats` backfills seat caps against LS's own `activation_limit`.
- **Old "unlimited" sentinels** — a prior Lemon Squeezy import used `999` to mean
  unlimited; `bin/rails licenses:normalize_unlimited` converts those to real
  unlimited (nil) seats.

---

## 8. Affiliate program (optional)

Let partners earn commission for sales they refer. An affiliate shares a link with
`?ref=THEIR_CODE`, a 60-day cookie on your marketing site remembers it, and any
purchase that follows credits them. Affiliates are **global** — one code, one rate,
one dashboard works across every product you sell. It's off until you configure the
two settings below; nothing changes for products that don't.

**How commission is counted.** It's frozen at sale time on the pre-tax amount
(`amount_subtotal`), so a later rate change never rewrites what you already owe, and
you never pay a cut of the VAT Stripe collected but you never received. Renewals
don't pay commission. A refund removes that sale from what's owed.

**Payouts are manual.** Stripe Managed Payments (merchant of record) can't also run
Stripe Connect, so Licencio can't auto-transfer commission. Instead you get an
honest ledger: the affiliate's dashboard and their admin page show exactly what's
owed; you pay by hand (PayPal / Wise / bank) and click **Mark paid** to record it.

### Turn it on

1. **Email template.** Add one Loops template — the affiliate dashboard magic link —
   and paste its id into **one** product's `affiliate_transactional_id` field
   (Products → edit → Email). A global affiliate isn't tied to a product, so the
   first product with this set becomes the sender for all affiliate emails; it reuses
   that product's `loops_api_key` and `sender_email`. The template receives
   `magic_link_url`, `affiliate_name`, `sender_email`.
2. **Suggested links.** On each product you want affiliates to promote, set
   **`affiliate_landing_url`** (Products → edit → Stripe section) to that product's
   marketing URL, e.g. `https://my-app.com`. The affiliate dashboard shows a ready
   `…?ref=CODE` link per product — but any page works (see the snippet below).

### Marketing-site snippet

Put this on your marketing site (once, site-wide). It stores a `?ref=` code for 60
days and appends it to every Licencio buy link on the page. **Call `attributeRef()`
from your cookie-consent "accept" handler** — the attribution cookie isn't strictly
necessary, so gate it on consent (a visitor who declines simply isn't attributed):

```html
<script>
  function attributeRef() {
    const p = new URLSearchParams(location.search).get("ref");
    if (p) document.cookie = `ref=${encodeURIComponent(p)}; max-age=5184000; path=/; samesite=lax`;
    const ref = document.cookie.match(/(?:^|;\s*)ref=([^;]*)/)?.[1];
    if (ref) document.querySelectorAll("a[href*='/api/checkout']").forEach((a) => {
      const u = new URL(a.href); u.searchParams.set("ref", decodeURIComponent(ref)); a.href = u;
    });
  }
  // e.g. onConsentAccepted(attributeRef)
</script>
```

That's the whole integration. The buy links themselves are unchanged (§4a) — an
unknown or unapproved code is simply ignored and checkout proceeds as normal.

### Approving affiliates

1. An applicant fills in the public form at **`/affiliate/signup`** (name, email,
   preferred code, payout email). Link to it from your site or share it directly.
2. They land as **pending** and are emailed **nothing** yet.
3. In **`/admin` → Affiliates**, open the applicant and click **Approve**. That
   activates their code and emails them their dashboard magic link. (Edit sets their
   commission rate — the default is 20%.)

An affiliate signs into **`/affiliate`** the same passwordless way customers use the
portal: a 30-minute, reusable magic link, re-requested any time at
`/affiliate/recoveries/new`.

### Paying and reconciling

Open an affiliate in **`/admin` → Affiliates**:

- **Payable** — commission that's cleared a 30-day refund hold and wasn't refunded.
- **Paid out** — the sum of payouts you've recorded.
- **Owed now** — Payable − Paid out. This is what to send.

Pay them however you agreed, then use **Record a payout** (amount in **cents**,
currency, an optional note like a Wise transaction id) to log it. The affiliate sees
the same numbers and their payout history on their own dashboard — no email needed.

> **Refund after you've paid?** The 30-day hold exists to avoid paying on a sale
> that gets refunded. If a refund lands *after* you already paid out, that
> commission is simply money you've eaten — record the next payout for less to
> settle it, or absorb it. There's no automatic clawback.
