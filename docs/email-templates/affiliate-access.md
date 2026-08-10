<!--
Loops transactional template → product.affiliate_transactional_id
Subject: Your affiliate dashboard link
Data variables: affiliate_name, magic_link_url, sender_email

One template, sent for both cases: when you approve an affiliate, and when an
approved affiliate requests a fresh sign-in link. Keep the copy generic so it
reads well either way. Affiliates are global (not per-product), so no
product_name here — set affiliate_transactional_id on ONE product and it sends
all affiliate emails through that product's Loops config.
-->

# Your affiliate dashboard

Hi {DATA_VARIABLE:affiliate_name}, here's your secure link to your affiliate dashboard. Open it to grab your referral link and see your sales, commission, and payouts.

[Open my dashboard]({DATA_VARIABLE:magic_link_url})

This link is good for 30 minutes and only works for you. Need a new one? Request another from the affiliate sign-in page.

---

Questions? Just reply to {DATA_VARIABLE:sender_email}.
