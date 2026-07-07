<!--
Loops transactional template → product.expiry_reminder_transactional_id
Subject: Your {DATA_VARIABLE:product_name} license expires on {DATA_VARIABLE:expires_at}
Data variables: product_name, license_keys, expires_at, magic_link_url, sender_email
-->

# Your license expires soon

Heads up — your **{DATA_VARIABLE:product_name}** license expires on **{DATA_VARIABLE:expires_at}**. Renew now to keep your updates and activations without interruption.

**Your license key**

```
{DATA_VARIABLE:license_keys}
```

[Renew my license]({DATA_VARIABLE:magic_link_url})

---

Questions? Just reply to {DATA_VARIABLE:sender_email}.
