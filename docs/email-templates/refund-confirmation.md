<!--
Loops transactional template → product.refund_transactional_id
Subject: Your {DATA_VARIABLE:product_name} refund has been processed
Data variables: product_name, license_keys, sender_email (magic_link_url also available)
-->

# Your refund is on its way

We've processed your refund for **{DATA_VARIABLE:product_name}**. Your license below has been deactivated and it may take a few business days for the funds to appear.

**Deactivated license**

```
{DATA_VARIABLE:license_keys}
```

Refunded by mistake, or changed your mind? Reply to {DATA_VARIABLE:sender_email} and we'll help you get set up again.
