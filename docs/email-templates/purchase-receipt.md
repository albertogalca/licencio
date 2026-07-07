<!--
Loops transactional template → product.purchase_transactional_id
Subject: Your {DATA_VARIABLE:product_name} license
Data variables: product_name, license_keys, amount, magic_link_url, sender_email
-->

# Thanks for your purchase

Your **{DATA_VARIABLE:product_name}** license is ready. Keep this email — your license key is below.

**License key**

```
{DATA_VARIABLE:license_keys}
```

Amount paid: **{DATA_VARIABLE:amount}**

[Access your license & downloads]({DATA_VARIABLE:magic_link_url})

---

Questions? Just reply to {DATA_VARIABLE:sender_email}.
