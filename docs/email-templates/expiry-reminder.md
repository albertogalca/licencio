<!--
Loops transactional template → product.expiry_reminder_transactional_id
Subject: Your {DATA_VARIABLE:product_name} updates end on {DATA_VARIABLE:expires_at}
Data variables: product_name, license_keys, expires_at, renew_url, magic_link_url, sender_email

`expires_at` arrives pre-formatted for reading ("August 3, 2026"), not ISO-8601.

Use `renew_url` here, not `magic_link_url`. Both are sent (magic_link_url is a base
variable on every template), but the renew link goes straight to the renewal, while the
magic link only opens the portal.

WORDING MATTERS on a `time_limited` product: what expires is the update window, not the
app. Saying "your license expires" tells a paying customer their app is about to stop
working, which is both alarming and untrue. Say updates.
-->

# Your update window ends soon

Your **{DATA_VARIABLE:product_name}** updates run until **{DATA_VARIABLE:expires_at}**.

After that, {DATA_VARIABLE:product_name} keeps working exactly as it is — same app, same
files, nothing removed. You just stop receiving new versions. Renew whenever you want
them again.

**Your license key**

```
{DATA_VARIABLE:license_keys}
```

[Renew my updates]({DATA_VARIABLE:renew_url})

---

Questions? Just reply to {DATA_VARIABLE:sender_email}.
