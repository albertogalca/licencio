<img src="../public/icon.svg" alt="Licencio" width="40" height="40" align="left">

# Operating guide

This is the guide for running your store: setting up a product, connecting Stripe, putting
buy links on your website, and handling licenses after they're sold.

It assumes Licencio is running and you have an admin login. If not, start with
[self-hosting](self-hosting.md). Building the app side, the part that activates a key and
checks the token? That's [client integration](client-integration.md).

Three kinds of people and programs talk to Licencio:

| Who | Where | How they sign in |
|-----|-------|------------------|
| You | `/admin` | email and password |
| Your buyers | `/portal` | a magic link sent by email |
| Your app, on a device | `/api/licenses/*` | the Product's `X-Api-Key` |

## Contents

1. [Create a product](#1-create-a-product)
2. [Update policies](#2-update-policies)
3. [Email](#3-email)
4. [Sell from your website](#4-sell-from-your-website)
5. [The customer portal](#5-the-customer-portal)
6. [Manage licenses](#6-manage-licenses)
7. [Move from another store](#7-move-from-another-store)
8. [If this server ever goes away](#8-if-this-server-ever-goes-away)

---

## 1. Create a product

A **Product** is one app you sell. It holds its own Stripe account, email settings and
signing key, so one Licencio can sell several apps that never share anything.

In `/admin`, go to **Products → New product**.

### Identity (locked after the first save)

| Field | Example | What it is |
|-------|---------|------------|
| `slug` | `my-app` | the short id your website uses in buy links |
| `bundle_identifier` | `com.example.myapp` | your app's bundle id |
| `license_prefix` | `MYAPP` | the start of every license key. It can't change later, because it's in every key you've issued |

### Connect Stripe

Every Product bills through its own Stripe account. You paste the Stripe values on the
Product, not in `.env`.

| Field | Where to find it in Stripe |
|-------|----------------------------|
| `stripe_product_id` (`prod_…`) | Product catalog → your product |
| `stripe_secret_key` (`sk_…`) | Developers → API keys |
| `stripe_webhook_secret` (`whsec_…`) | Developers → Webhooks → your endpoint → Signing secret |
| `checkout_success_url` | your own "thanks for buying" page |
| `checkout_cancel_url` | your pricing page. Buyers who back out land here, and so do stale buy links |

Once `stripe_product_id` is set, both checkout URLs are required.

Then do 3 things in Stripe.

**Add a Price for each option you sell.** Each Price on the Stripe product becomes a
**variant** you can sell. Give it a nickname ("2 Macs"), a one-time amount, and a metadata
key `seats`:

| `seats` value | Means |
|---------------|-------|
| `1`, `2`, `5`… | the license covers that many devices |
| `unlimited` or `0` | the license covers every device |
| missing | the Product's default seats are used |

If a Price has no `seats` and the Product has no default seats, checkout refuses it with a
`503`. That's on purpose, so you never sell an uncapped license by accident. You can add,
rename and reprice variants in Stripe at any time, and the price doesn't have to scale with
seats.

**Register the webhook.** Add an endpoint at `https://YOUR_HOST/webhooks/stripe/PRODUCT_ID`
(the Product's edit page shows the exact URL) and subscribe it to
`checkout.session.completed` and `charge.refunded`. Paste its signing secret into
`stripe_webhook_secret`. The webhook is what turns a payment into a license and a refund
into a revocation.

To test locally, forward Stripe's events to your machine and paste the `whsec_…` it prints:

```bash
stripe listen --forward-to localhost:3000/webhooks/stripe/PRODUCT_ID
```

**Turn on Managed Payments.** Checkout runs through Stripe Managed Payments, so Stripe is
the merchant of record and handles sales tax for you. Until it's enabled on your Stripe
account, checkout fails.

After you save with Stripe keys, the edit page lists your variants live from Stripe (price
id, nickname, seats, amount).

### Licensing settings

| Field | What it does |
|-------|--------------|
| `name` | display name, shown to buyers |
| `update_policy` | the default for every license. See [update policies](#2-update-policies) |
| `update_duration_days` | for `time_limited`: how long a license gets updates, e.g. `365` |
| `current_version` | for `versioned`: your latest major version. Starts at 1 |
| `max_activations_default` | default seats, used when a Price has no `seats` metadata |
| `trial_days` | lets an app run without a key for this many days. Blank means no trial |
| `download_url` | optional. Shows a download button in the customer portal |

A trial is one per Mac. The app activates with no license key and gets a trial license
bound to that device. `GET /api/admin/products/:slug/trials/cohorts` reports how many trials
started, are still running and converted, week by week, for the last 8 weeks.

### Keys Licencio makes for you

Copy these from the Product's edit page after saving:

| Key | Where it goes |
|-----|---------------|
| `api_key` (`prod_…`) | inside your app, sent as the `X-Api-Key` header. It ships in your binary, so treat it as public |
| `eddsa_public_key` | inside your app, to verify tokens offline. Safe to publish |

Rotating the API key breaks every build that has the old one, so only do it if you must:

```bash
bin/rails "products:rotate_api_key[my-app]"
```

### Branding (optional)

The pages buyers see (recovery, sign-in, the portal) can use your look instead of
Licencio's.

| Field | What it does |
|-------|--------------|
| `logo_url` | shown above the form at 32px tall. Use an SVG or a 2x PNG |
| `accent_color` | a hex color like `#2563eb`, for buttons, links and focus rings. Lighter and darker shades are mixed from it |
| `background_color` | a hex color for the page behind the card |

Blank keeps the default. Colors must be hex and the logo must be an `http(s)` URL, or the
form won't save. The recovery page picks the brand from `?product=<slug>`, and the portal
uses the Product the buyer's magic link came from.

The rest of the form (gift cards, renewal and lifetime upgrade prices, regional pricing,
issuance key, more email templates) is covered in
[optional features](optional-features.md).

---

## 2. Update policies

Every license either gets updates or doesn't, and its **update policy** decides which. A
Product sets the default, and any single license can override it. None of the policies
ever stop the app from running; they only decide whether new versions are included.

| Policy | The license gets updates… | Set with |
|--------|---------------------------|----------|
| `lifetime` | forever | nothing else |
| `time_limited` | for a fixed time after purchase, then the buyer can renew | `update_duration_days` |
| `versioned` | for its major version only | `current_version` on the Product, `Version` on the license |

Your app reads the answer from the token's `update_eligible` claim. See
[client integration](client-integration.md).

**To sell 2 policies for the same app** (say a "v1" license and a "lifetime" one), override
per license:

- At checkout, add metadata `update_policy` (e.g. `lifetime`) to a Stripe Price. Licenses
  bought with that Price get it. Other Prices use the Product default.
- By hand, set a license's Update policy in `/admin`. Blank means it follows the Product.

**When you ship a new major version,** raise the Product's `current_version` (1 → 2). Every
`versioned` license still on `Version` 1 stops getting updates. To sell a paid upgrade,
raise that buyer's license `Version` to 2 once they've paid.

---

## 3. Email

Licencio sends email through **Loops**, with one Loops template per moment. Every template
is optional: leave its id blank and that email is skipped. Purchases still go through, and
buyers can always get their key back through the recovery form.

| Field | Where in Loops |
|-------|----------------|
| `loops_api_key` | Settings → API. Blank uses `LOOPS_API_KEY_DEFAULT` |
| `sender_email` | the address you send from |
| `loops_mailing_list_id` | optional. Buyers are added to this list on purchase |

The templates:

| Sent when | Field | Variables |
|-----------|-------|-----------|
| a purchase or renewal completes | `purchase_transactional_id` | `product_name`, `license_keys` (the key just bought), `amount`, `magic_link_url`, `sender_email` |
| a buyer recovers their key, or you issue one by hand | `loops_transactional_id` | `product_name`, `license_keys` (all of them, one per line), `magic_link_url`, `sender_email` |
| a purchase is fully refunded | `refund_transactional_id` | `product_name`, `license_keys`, `magic_link_url`, `sender_email` |
| about 7 days before a `time_limited` license expires | `expiry_reminder_transactional_id` | `product_name`, `license_keys`, `expires_at` (e.g. "August 3, 2026"), `renew_url`, `magic_link_url`, `sender_email` |

Ready-to-paste copy for each lives in [`email-templates/`](email-templates/). Create each
one in Loops and paste its id into the matching field. Loops merge tags look like
`{DATA_VARIABLE:product_name}`.

Every `magic_link_url` signs the buyer into the portal for that Product and works for 30
minutes.

On purchase, the buyer is also added to your Loops audience as a contact
(`source: "Stripe"`). A full refund unsubscribes them, unless they still hold another
active license for that Product.

Templates for unlock codes, gifts and deal codes are in
[unlock by email](unlock-by-email.md), [optional features](optional-features.md) and
[deal codes](deal-codes.md).

---

## 4. Sell from your website

Your marketing site needs 2 links: a buy button and a "lost your license?" link. Both work
from plain HTML. Replace `YOUR_HOST` with your Licencio host.

### Buy button

The simplest buy button is a plain link. Licencio builds the Stripe Checkout session and
redirects the buyer straight to it, so a static site needs no JavaScript:

```html
<a href="https://YOUR_HOST/api/checkout?product_slug=my-app&price_id=price_123">
  Buy My App
</a>
```

Keep `product_slug` first in the query string. Licencio treats links that start with
`price_id=` as scrapers and sends them to your pricing page. Known bots and link previews
get the same treatment, so they don't burn Stripe sessions.

If you'd rather use JavaScript, `POST /api/checkout` with the same fields returns
`{ "url": "…" }` to redirect to:

```html
<button id="buy" data-price="price_123">Buy My App</button>
<script>
  document.getElementById("buy").addEventListener("click", async (event) => {
    const response = await fetch("https://YOUR_HOST/api/checkout", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ product_slug: "my-app", price_id: event.target.dataset.price }),
    });
    const { url } = await response.json();
    window.location = url;
  });
</script>
```

Optional fields, in the query string or the body:

| Field | What it does |
|-------|--------------|
| `email` | prefills the email on Checkout |
| `renew_license_key` | renews that license instead of issuing a new one |
| `promo` | a Stripe promotion code to apply |
| `client_reference_id` | passed through to the Stripe session |

The price must belong to the Product's Stripe product, or you get a `404`. Checkout shows a
coupon field.

To avoid copying prices into your site by hand, fetch them when the page loads. Variants
come back cheapest first:

```
GET https://YOUR_HOST/api/products/my-app/variants
→ { "variants": [ { "price_id": "price_…", "name": "Pro", "amount_cents": 4900, "seats": 3 }, … ] }
```

`GET /api/products/my-app/stats` returns how many distinct customers the Product has, if
you want a "used by 1,200 people" line.

When the buyer pays, the webhook creates the license and emails it. There's nothing else
to wire up.

### "Lost your license?" link

This sends the buyer their keys and a portal sign-in link. Link to the built-in form, with
the Product in the URL:

```html
<a href="https://YOUR_HOST/portal/recoveries/new?product=my-app">
  Lost your license? Recover it
</a>
```

The same link is how buyers manage their licenses, because the email it sends signs them
into the portal. You don't need a separate "manage" page.

To build your own form instead, call `POST /api/licenses/recover` from your server with the
Product API key. It always returns `200`, whether or not the email has bought anything. See
the [API reference](api.md).

---

## 5. The customer portal

Buyers never get a password. They sign in with a magic link from a purchase email or the
recovery form, and land on `/portal`, scoped to the Product the link came from. A link for
one app never shows another app's licenses.

In the portal a buyer can:

- see their keys, expiry dates and every device using each key,
- free up a seat by deactivating a device,
- renew a `time_limited` license when it's expired or within 30 days of expiring,
- add seats, if you sell seat upgrades (see [optional features](optional-features.md)),
- download the app, if the Product has a `download_url`.

Sign-in links last 30 minutes and can be opened more than once in that time. Someone who
owns 2 of your apps can hold a live link for each. An expired link sends them back to the
recovery form for the right Product.

---

## 6. Manage licenses

Most licenses create themselves: the Stripe webhook issues one per payment. Stripe retries
are safe, because Licencio only fulfills each payment once. You'll open the admin for
support, comps and refunds.

**Find a license.** The search box matches the key, the buyer's email or name, the Product
and the status. Lists show 50 rows per page.

**Issue one by hand** (for comps, support or testing). Go to **Licenses → New**, pick the
Product, and optionally enter an email (a Customer is created if it's new). Set seats
(blank means unlimited), status and an optional expiry. The key is generated on save. If
you attached an email and Loops is set up, the buyer gets their key and a portal link.

**Resend an email.** A license's edit page can resend its lifecycle emails: the access
link, the receipt, the refund notice and the expiry reminder.

**Change the status.** A license is `active`, `inactive`, `expired` or `refunded`. Only an
`active` license can activate new devices. A full Stripe refund sets `refunded` for you,
sends the refund email if you set one up, and unsubscribes the buyer from Loops. Set the
others by hand when you need to revoke a license yourself.

A status change doesn't reach a device that's offline. Its token keeps working until the
7-day lease runs out. An online app re-activates in the background and locks within a day
or so. See [token lease](client-integration.md#token-lease-and-revocation).

**Devices.** Each activation takes a seat. Your app frees seats through the API, buyers free
them in the portal, and you can deactivate any device from the **Activations** screen or the
license page.

**Customers** is read-only. Search by email and open one to see their licenses and devices.

---

## 7. Move from another store

If you sell somewhere else today (Gumroad, Lemon Squeezy, Polar), import your existing
buyers as licenses. Keep their original key strings, so every buyer's app keeps working
with the key they already have.

**Import endpoint.** `POST /api/admin/migrations/import` takes CSV or JSON rows and a
`source` (`lemon_squeezy` or `polar`), authenticated with `ADMIN_API_KEY`. Each row is one
license:

| Column | Notes |
|--------|-------|
| `product_slug` | required |
| `license_key` | required. Rows whose key already exists are skipped, so you can run it again |
| `email`, `name` | optional. A blank email makes an unclaimed license the buyer claims later |
| `status` | optional |
| `max_activations` | optional. Blank uses the Product's default seats |
| `expires_at` | optional |
| `update_policy`, `licensed_version` | optional per-license overrides |

**Lemon Squeezy, through its API.** Pull keys with an LS API token. Only new keys import.

```bash
LS_TOKEN=… bin/rails lemon_squeezy:import
bin/rails lemon_squeezy:verify_seats   # match seat caps to LS's activation_limit
```

Older imports used `999` seats to mean unlimited. This converts them:

```bash
bin/rails licenses:normalize_unlimited
```

**Polar** has no CSV export, so keys come through its API with an Organization Access Token.
`lib/tasks/polar.rake` is a worked example. It's written for one specific product, so copy
it and change the product slug and ids before running it.

---

## 8. If this server ever goes away

People who buy software they keep worry about one thing: a license check that outlives the
company. Plan for it once, now, while it's cheap.

**Do this today.** Export each Product's signing key and keep it somewhere that outlives
you: a password manager your executor can open, a safe, a sheet of paper. The key is
encrypted in this database, and the day you need it is the day the database is gone.

```bash
bin/rails "licenses:signing_key[my-app]"
```

**Store the key, not a token.** A rescue token can't be revoked, because no app ever checks
it again. One that leaks is free software forever, and the only fix is a new signing key,
which locks out every install you've shipped. Mint the token only on the day you need it.

```bash
# When the time comes, if this app still runs:
bin/rails "licenses:rescue_token[my-app]"
```

**If nothing else is left.** Rails, the database and this repo might all be gone. The key is
enough: any machine with Node can mint the token. This script is short so you can retype it
from paper.

```js
// node mint.mjs <base64-signing-key>
import { createPrivateKey, sign } from 'node:crypto'
const b64url = (b) => Buffer.from(b).toString('base64url')
const key = createPrivateKey({
  key: Buffer.concat([
    Buffer.from('302e020100300506032b657004220420', 'hex'),
    Buffer.from(process.argv[2], 'base64')
  ]),
  format: 'der',
  type: 'pkcs8'
})
const claims = {
  hardware_id: '*',
  license_key: 'OFFLINE',
  expires_at: null,
  update_eligible: true,
  nonce: '*',
  iat: Math.floor(Date.now() / 1000),
  exp: 4102444800
}
const input = [{ alg: 'EdDSA', typ: 'JWT' }, claims]
  .map((h) => b64url(JSON.stringify(h)))
  .join('.')
console.log(`${input}.${b64url(sign(null, Buffer.from(input, 'ascii'), key))}`)
```

Print this section and keep it next to the key. Together they're the whole kit.

**What a rescue token is.** A normal offline token, signed with the key your app already
trusts, but with `"*"` where a normal token names one device and one nonce. Every install
accepts it, and none of them call home again. Your app has to treat `"*"` as "any device"
for this to work, so **test it in your app before you need it.**

**How to use it.** Publish the token (a blog post, the README, a pinned issue) and tell
people to paste it into the license field instead of a key. There's no server involved, so
it keeps working forever. That's also why you don't mint one early and leave it in a
terminal or a note while you're still selling.

**One more thing for your app.** Don't let it lock itself on a silent failure. A server that
doesn't answer isn't proof that a license is bad, so treat a timeout as "keep working" and
only lock on a clear refusal from a server you actually reached.
