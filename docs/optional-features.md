<img src="../public/icon.svg" alt="Licencio" width="40" height="40" align="left">

# Optional features

Everything here is off until you configure it. A Product that sets none of it sells
license keys exactly as the [operating guide](operating-guide.md) describes.

- [Renewal price](#renewal-price)
- [Lifetime upgrade](#lifetime-upgrade)
- [Seat upgrades](#seat-upgrades)
- [Gift cards](#gift-cards)
- [Bundle stores](#bundle-stores)
- [Checkout recovery](#checkout-recovery)
- [Student discount](#student-discount)
- [Regional pricing](#regional-pricing)
- [App Store purchases](#app-store-purchases)

## Renewal price

By default, renewing a `time_limited` license charges whatever Price the buyer picks. To
charge a cheaper "another year of updates" price instead, create that Price in Stripe and
paste its id into the Product's **Renewal price ID**.

The renewal price is hidden from your storefront and refused outside a renewal, so nobody
can buy a new license at the renewal price. Buyers renew from the portal, the expiry
reminder email (`renew_url`), or `/portal/renewals/new?license_key=…`.

## Lifetime upgrade

A Stripe Price that moves a `time_limited` license to `lifetime`: same key, every future
version, nothing left to renew. Paste its id into **Lifetime upgrade price ID** and the
portal offers it to every eligible license. Like the renewal price, it's hidden from the
storefront and refused to anyone who doesn't already own the Product.

## Seat upgrades

Let a buyer add devices to the key they already have. In Stripe, create a Price for each
step with 2 metadata keys:

| Metadata | Example | Meaning |
|----------|---------|---------|
| `upgrade_from_seats` | `1` | the seat count the license has now |
| `seats` | `3` | the seat count after the upgrade |

The price is whatever the step costs, not the full price. A license only sees the upgrades
that start from its current seat count. Buyers reach them in the portal or at
`/portal/upgrades/new?product=my-app`, where they type their key, see their options and
pay. Upgrade prices never show on your storefront.

## Gift cards

A buyer pays for a license for someone else. Checkout creates no license. It creates a
12-character code and emails the buyer a link to a printable card. Whoever opens the card
and enters their email gets the license, as if they'd bought it.

Setup:

1. Build a card page on your storefront and paste its URL into **Gift card URL**. The code
   arrives in the URL fragment (`https://example.com/gift#ABCD…`).
2. Create a Loops template with `card_url`, `gift_code` and `to_name`, and paste its id
   into **Gift card transactional ID**.
3. Add `gift=1` to a buy link. Checkout then asks who it's for, who it's from, and for an
   optional note.

Your card page calls the gift endpoints in the [API reference](api.md#gifts-and-the-app-store):
`GET /v1/gifts/:code` to show the card, `GET /v1/gifts/checkout/:session_id` right after
checkout (it returns `404` until the webhook lands, so ask again), and
`POST /v1/gifts/:code/redeem` to open it. A refund before redemption voids the code. A
refund after revokes the license.

## Bundle stores

Some bundle stores (BundleHunt, for example) call your server once per sale and show the
response to the buyer. Licencio answers with the bare key as plain text.

Bundle stores use a separate **issuance key**, never the app's API key, because the API key
ships in every build and would let anyone mint licenses. Create or rotate it with:

```bash
bin/rails "products:rotate_issuance_key[my-app]"
```

Give the store this endpoint:

```bash
curl -X POST https://YOUR_HOST/api/licenses/issue \
  -H "X-Api-Key: <issuance key>" \
  -d "email=ada@example.com" -d "name=Ada" -d "seats=2"
# → MYAPP-2C295B41-135C-4C2B-AFA6-5DEB9C05A733
```

`seats` is 1 to 10 and defaults to the Product's default seats. `unlimited` works only if
the Product has **Bundle stores may issue unlimited seats** checked. The buyer gets a portal link by email
and joins your Loops audience. There's no idempotency key, so a store that retries a call
mints a second key.

## Checkout recovery

When a buyer leaves Stripe Checkout without paying and agreed to promotional email, Stripe
can send them back a link to the same checkout. Licencio emails it once.

1. In the Stripe dashboard, accept the promotions terms. Until you do, checkouts that ask
   for consent fail, so do this first.
2. Subscribe your Stripe webhook to `checkout.session.expired` as well.
3. Create a Loops template and paste its id into **Checkout recovery transactional ID**.

Leave the field blank to keep it off.

## Student discount

Your storefront posts a school email address, and Licencio emails that address a Stripe
promotion code. The code only reaches someone who can read a school inbox.

```bash
curl -X POST https://YOUR_HOST/api/students/discount \
  -H "Content-Type: application/json" \
  -d '{"product_slug":"my-app","email":"ada@ox.ac.uk"}'
# → { "sent": true }
```

An address counts as academic when it ends in `.edu`, `.edu.xx` or `.ac.xx` (`mit.edu`,
`ox.ac.uk`, `unimelb.edu.au`). Schools on a plain national domain don't match and have to
email you. Each address gets 1 email per Product per day, and each IP 5 requests a minute.

The template gets `discount_code`, `pricing_url` (your `checkout_cancel_url`),
`product_name` and `sender_email`.

There's no admin field for this yet. Set both values from a Rails console:

```ruby
Product.find_by!(slug: "my-app").update!(
  student_discount_code: "STUDENT40",
  student_transactional_id: "<loops template id>")
```

## Regional pricing

Charge different prices by country, beyond what currencies alone allow. Each country sits
in one of 5 bands, and each band is its own set of Stripe prices. A buyer keeps their band
for every renewal and upgrade after.

It takes 3 pieces, and it's the most involved feature here:

1. A band table for the Product at `config/regional_bands/<slug>.json`, generated by
   `scripts/regional_bands.rb`.
2. Stripe prices for each band, tagged with `sku` and `band` metadata and found by lookup
   key. `scripts/stripe_prices.rb` shows how they're created.
3. Your storefront signs the visitor's country (from Cloudflare, say) into the buy link as
   `region=CC.issued_at.signature`, an HMAC-SHA256 with a shared secret. Paste the same
   secret into **Regional pricing secret**.

A missing, forged or day-old token falls back to band 1, the full price, so the storefront
can only ever fail toward full price. Read `app/models/product/regional_pricing.rb` before
you set this up.

## App Store purchases

An iPhone app can let its buyers claim a desktop license. The app posts its StoreKit 2
signed transaction to `POST /v1/iap/claim` with an email, and Licencio verifies it against
Apple's root certificate and issues the license that purchase includes.

For refunds, point the app's App Store Server Notifications V2 URL at
`https://YOUR_HOST/webhooks/app_store/PRODUCT_ID`. `REFUND` and `REVOKE` revoke the license.
A later `REFUND_REVERSED` doesn't restore it.

**This one isn't configurable yet.** Which App Store product id maps to which Product,
tier and update policy lives in `AppStoreTransaction::GRANTS`, in
`app/models/app_store_transaction.rb`. Add your own entry there.
