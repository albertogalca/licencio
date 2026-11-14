<img src="../public/icon.svg" alt="Licencio" width="40" height="40" align="left">

# Deal codes

For selling on AppSumo or any deal site that hands buyers a code. You generate a list of
codes, upload it to the deal site, and buyers redeem their code on a Licencio page for a
license.

## How redemption works

The buyer opens `https://YOUR_HOST/redeem?product=my-app`, enters their code and their
email, and gets a license key on the page and by email.

- The first code for an email creates a license with 1 seat.
- Each further code for the same email adds 1 seat to that license. The key stays the same.
- An email can stack 4 codes at most.
- If the email already has a license for the Product, bought anywhere, the codes add to
  that one.

The `?product=` part only puts your logo on the page. The code itself says which Product
it's for.

The deal terms (1 seat per code, updates forever, 4 codes per email) live in
`RedemptionCode::DEALS` in `app/models/redemption_code.rb`. Edit them there for a
different deal.

## Generate the code list

```bash
bin/rails "codes:generate[my-app]" OUT=appsumo-codes.csv          # 10,000 codes
bin/rails "codes:generate[my-app,500]" OUT=appsumo-extra.csv      # any count
```

The file has one code per line, no header, in random order. Each code is 16 characters of
uppercase letters and digits, without `0`, `O`, `1`, `I` or `L`, so nobody misreads them.

**This file is the only copy of the codes.** The database keeps a SHA-256 digest and the
last 4 characters, nothing more. Upload the file to the deal site, then store it somewhere
safe or delete it.

Always pass `OUT`. Without it the codes go to stdout, and on a server any boot warning
lands in the file as an extra line. In a container, write to `/tmp`, copy it out, and
delete it:

```bash
docker compose exec web bin/rails "codes:generate[my-app]" OUT=/tmp/codes.csv
docker compose cp web:/tmp/codes.csv ./appsumo-codes.csv
docker compose exec web rm /tmp/codes.csv
```

To load a list made somewhere else (same format, 3 to 200 characters per code):

```bash
bin/rails "codes:import[my-app,path/to/codes.csv]"
```

Duplicates are skipped, so running an import twice is safe.

## Revoke a code

When the deal site refunds a buyer, revoke their code. In the admin, open **Codes**, search
for the code or the buyer's email, and press **Revoke**. Or from a script:

```bash
curl -X POST https://YOUR_HOST/api/admin/redemption_codes/revoke \
  -H "Authorization: Bearer $ADMIN_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"code":"ABCDEFGH23456789"}'
```

Revoking takes 1 seat back from the license and signs out the newest device past the new
limit. At 0 seats the license becomes inactive. A revoked code can't be redeemed again, and
it stops counting toward the email's 4.

## Emails

2 Loops templates, set per Product in the admin. Leave a field blank to skip that email.

| Sent when | Field | Variables |
|-----------|-------|-----------|
| a code creates a license | `redemption_transactional_id` (Code redeemed) | `license_keys`, `macs` |
| a code adds a seat | `seats_added_transactional_id` (Code stacked) | `license_keys`, `macs` |

Copy for both is in [`email-templates/code-redeemed.md`](email-templates/code-redeemed.md)
and [`email-templates/code-stacked.md`](email-templates/code-stacked.md).

## Limits

The redeem page allows 20 attempts per IP and 10 per email per hour.
