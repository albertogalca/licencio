<!--
Loops transactional template → product.unlock_transactional_id
Subject: Your {DATA_VARIABLE:product_name} code is {DATA_VARIABLE:code}
Data variables: code, product_name

Sent by UnlockCodeJob. Only these two variables are passed — no magic_link_url and no
sender_email — so don't reference any others.

This email IS the unlock flow. If it doesn't arrive, or the digits are hard to find in
it, nobody gets into the app. So: the code goes first, large and on its own line, and
nothing above it competes for attention. Putting it in the subject line too means most
people never have to open the email at all.

The code lives ten minutes and allows five wrong tries (LoginCode::TTL and
LoginCode::MAX_ATTEMPTS). Say the ten minutes — a code that dies silently reads as a
broken app rather than an expired code.

WORDING MATTERS: there is no account here, and never was. Nobody signed up, nothing was
created, nothing can be locked out. Say "your Cozy license", never "your account" — and
tell an unexpected recipient plainly that ignoring this costs them nothing, because a
six-digit code in a stranger's inbox is alarming otherwise.
-->

# Your unlock code

Here's the code to unlock **{DATA_VARIABLE:product_name}**:

```
{DATA_VARIABLE:code}
```

Type it into the app to unlock your {DATA_VARIABLE:product_name} license. The code works
for 10 minutes — if it runs out, just ask for a new one.

---

Didn't ask for this? Nothing happened and nothing was created — there's no account here,
only your license and your email address. You can ignore this message.

Questions? Just reply to this email.
