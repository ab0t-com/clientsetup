# Quickstart — connect your service to ab0t in minutes

**Start metering usage or charging your customers without writing any auth code.**
No credentials to request, no support ticket, no OAuth plumbing. One command
registers your service as a consumer and hands you a scoped API key. Wire in one
environment variable and your very next call is authenticated.

> **You'll do this once, in about five minutes:**
> install → see what's available → connect → wire one env var → make your first call.

**Before you start:** all you need is a terminal. You do *not* need an ab0t
account set up in advance, the provider's credentials, or a checkout of any ab0t
repository. `authsetup` creates everything for you.

---

## Step 1 — Install the CLI

```sh
curl -fsSL https://raw.githubusercontent.com/ab0t-com/clientsetup/main/install.sh | sh
authsetup version
```

You should see:

```
authsetup 0.4.0
```

*What just happened:* you installed a single, self-contained binary (checksum-verified,
no runtime dependencies). This is the only tool you need for everything below.

---

## Step 2 — See what you can connect to

```sh
authsetup providers
```

```
· env: prod  (auth: https://auth.service.ab0t.com)
· 2 mesh provider(s) accept self-serve consumers:

  billing  (billing)
    register : https://auth.service.ab0t.com/organizations/billing-api-consumers/auth/register  [signup enabled]
    tier     : Read-Only Consumers    2 perm(s) [default — zero-touch]
               billing.read, billing.cross_tenant
    connect  : authsetup connect billing

  payment  (payment)
    register : https://auth.service.ab0t.com/organizations/payment-api-consumers/auth/register  [signup enabled]
    tier     : Read-Only Consumers    2 perm(s) [default — zero-touch]
               payment.read, payment.cross_tenant
    connect  : authsetup connect payment

NEXT —
  authsetup connect <provider>   # self-register + mint a scoped key
  WHY: the directory only lists providers; connect facilitates the relationship.
```

*What just happened:* this is the live directory of ab0t services you can join
yourself. Each one lists a **tier** and the exact permissions it grants. The tier
marked **`[default — zero-touch]`** is the one anyone can connect to instantly —
no approval needed. (Add `--json` if you're scripting this.)

---

## Step 3 — Connect and get your key

Pick a provider from the list and connect. Use `--as` to name *your* service
(this just labels where your key is stored locally):

```sh
authsetup connect billing --as my-service
```

```
· env: prod  (auth: https://auth.service.ab0t.com)
· connecting "my-service" to provider "billing" (env prod)
✓ registered consumer account my-service-billing-a1b2c3d4@mesh-consumers.ab0t.com in billing-api-consumers
✓ minted scoped key key_9f...c2 for tier "Read-Only Consumers" (2 perms)

Env wiring — set these in your service (the key value is saved 0600, not printed):
  BILLING_SERVICE_URL=https://billing.service.ab0t.com
  BILLING_SERVICE_API_KEY=<ab0t_sk_live_… — read .api_key.key from ~/.authmesh/my-service/billing-consumer.prod.json>

  # If you use the ab0t-quota-go library (Go), it reads instead:
  AB0T_QUOTA_BILLING_URL=https://billing.service.ab0t.com

NEXT —
  wire the env vars above into your service, then call https://billing.service.ab0t.com
  the key value is in ~/.authmesh/my-service/billing-consumer.prod.json (.api_key.key) — load it from your secrets manager, never commit it
  WHY: the relationship is live; your service can now call the provider with the scoped key.
```

*What just happened:* in one command `authsetup` created a service account for
you, joined it to the provider's default tier, and minted a real API key scoped
to exactly that tier's permissions. Your key is written to a private `0600` file
on your machine — **it is never printed to the screen and never sent anywhere you
didn't ask.**

> **Two things to expect the first time:**
> - **A safety confirmation.** Because this creates a real account on production,
>   the CLI asks you to type `prod` once to confirm. Want to see exactly what it
>   would do first, with zero changes and no prompt? Add `--dry-run`.
> - **It's safe to re-run.** Run the same command again and it reuses your existing
>   key instead of making a second one (`✓ already connected … key reused`).

---

## Step 4 — Wire in the key

Copy the two env vars from the output into your service. Read the secret value
out of the saved file and load it however you manage secrets:

```sh
# The key value lives here (0600, never committed):
#   ~/.authmesh/my-service/billing-consumer.prod.json  →  field .api_key.key

export BILLING_SERVICE_URL=https://billing.service.ab0t.com
export BILLING_SERVICE_API_KEY="$(jq -r .api_key.key ~/.authmesh/my-service/billing-consumer.prod.json)"
```

*What just happened:* your service now knows where the provider lives and how to
authenticate to it. Send the key as an **`X-API-Key`** header on every request.

---

## Step 5 — Make your first authenticated call

```sh
curl -H "X-API-Key: $BILLING_SERVICE_API_KEY" \
  https://billing.service.ab0t.com/health
```

```
{"status":"ok"}
```

*What just happened:* that request was authenticated with your scoped key. To
prove the key is doing the work, try the same call **without** the header — you'll
get a `401`. That 200-with-key / 401-without is your confirmation the connection
is live.

---

## You're connected 🎉

In five minutes, with zero auth code, you have:

- a real, scoped API key for an ab0t service,
- one env var wired into your app,
- an authenticated first call.

## What to do next

Your key is the front door — here's what to build behind it:

- **Charge customers / manage subscriptions / record usage** (billing + payment):
  the **`billing-payment-integration`** skill covers proxy routes, checkout
  buttons, Stripe Checkout, the Customer Portal, and webhooks — no custom Stripe
  code on your side.
- **Meter usage or grant credits from a Go service:** the **`ab0t-quota-go-setup`**
  skill — the library reads `AB0T_QUOTA_BILLING_URL` and calls the provider with
  your key automatically.
- **Any other provider** (audit, resource, schema): use that provider's
  `*-service-api-reference` skill with the `X-API-Key` you just minted.

## If something goes wrong

| You see | What it means | Do this |
|---|---|---|
| `no mesh provider directory yet (… → 404)` | The directory isn't live on that environment | Try `--env prod` (the default) or `--env dev` |
| `did not grant every permission tier … requests` (403) | You asked for a tier above the zero-touch default | Connect to the default tier, or ask the provider to upgrade your account, then re-run with `--tier "<name>"` |
| `refusing to mutate PRODUCTION` (in CI) | A non-interactive run had no explicit target | Pass `--env prod` (or set `AUTHSETUP_ENV=prod`) to confirm intent |
| `creds dir … is inside a git repo and not gitignored` | Your key would land in a repo | Re-run with `--write-gitignore`, or keep the safe default `~/.authmesh/` |
| Where's my key? | — | `~/.authmesh/<your-service>/<provider>-consumer.<env>.json`, field `.api_key.key` |

For the full guided path (and the raw HTTP calls if you're not on Go), load the
**`connect-to-ab0t-mesh-provider`** skill, or see
[`skills/connect-to-ab0t-mesh-provider/`](skills/connect-to-ab0t-mesh-provider/).
