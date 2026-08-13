---
name: connect-to-ab0t-mesh-provider
description: Connect a client service (or agent) to an ab0t Auth Mesh provider using the authsetup binary — discover providers, self-register as a consumer, mint a scoped API key, and wire it in. Use when a service needs to CALL another ab0t mesh service (billing, payment, audit, resource, schema, …) and you have no provider credentials and no monorepo checkout; when you see "how do I get an API key for <service>", "connect to the mesh", "consume the billing/payment API", "authsetup providers", "authsetup connect"; when choosing a consumer tier; when a minted key 403s on a permission; or when deciding what to do with the key for billing/payment/quota. This is the ZERO-CREDENTIAL, client-side path (provider ran `run 08`); for the internal consumer path that needs the provider's admin creds see `mesh-service-accounts`/`mesh-consumer-account-sop`.
---

# Connect to an ab0t mesh provider

> **In this skill "consumer" = a SERVICE calling another service — NOT your product's human end users.** Human end users live in the `{service}-users` org (see the `auth-mesh-setup` skill); mesh consumers are other services and live in the `{service}-api-consumers` org.

Facilitate the relationship between your service and a provider's API in one
command — no provider credentials, no config files, no monorepo. The provider
opened self-serve consumption once (their `run 08`); you self-register and mint
a scoped key against the published directory.

## When this is the right path

Use this (`authsetup providers` / `authsetup connect`) when **you are the
consumer**, on your own infrastructure, and the provider has opened self-serve.
You only ever see a public org slug + a `register_url`.

Use `mesh-service-accounts` / `mesh-consumer-account-sop` (`authsetup run 07`)
instead when you operate INSIDE the ab0t monorepo and hold the provider's admin
credentials file — that path pre-dates the directory and grants arbitrary
permissions the provider implicitly trusts.

## Workflow

### 1. Install the binary (once)

```sh
curl -fsSL https://raw.githubusercontent.com/ab0t-com/clientsetup/main/install.sh | sh
authsetup version
```

### 2. Discover — who accepts self-serve consumers

```sh
authsetup providers            # human-readable
authsetup providers --json     # the raw directory (for scripting/agents)
```

Read, per provider: `service_id`, `register_url`, and each **tier** with the
permissions it grants. The tier marked `[default — zero-touch]` is the one
anyone can self-register into. Non-default tiers may withhold their permission
list and require the provider to upgrade your account after you connect.

If this prints "no mesh provider directory yet (… → 404)", the directory is not
deployed on that environment — pick the env with `--env` (default `prod`), or
fall back to the two raw HTTP calls in `references/manual-http-flow.md`.

### 3. Connect — self-register + mint a scoped key

```sh
authsetup connect billing --as my-service
```

What it does, end to end (idempotent — safe to re-run):
1. Resolves the provider from the directory (works even if unlisted, given its id).
2. Picks the tier (`--tier "<name>"`, else the default).
3. Registers a service account in the provider's `*-api-consumers` org
   (generates + persists a password; `--email <addr>` to choose the address).
4. Mints an `ab0t_sk_live_…` key holding **exactly** the tier's permissions.
   The auth service enforces the subset: it **403s** any permission the tier
   doesn't grant. `connect` turns that 403 into guidance (use the default tier,
   or ask the provider to upgrade you).
5. Saves the key **0600** to `~/.authmesh/<self>/<provider>-consumer.<env>.json`.
6. Prints the env wiring — **never the key value** (it stays in the file).

Preview without mutating: add `--dry-run`. Choose your creds namespace with
`--as <your-service>` (defaults to your config's `service.id`, else
`authmesh-consumer`).

### 4. Wire the key into your service

`connect` prints (for provider `billing`):

```sh
BILLING_SERVICE_URL=https://billing.service.ab0t.com
BILLING_SERVICE_API_KEY=<read .api_key.key from ~/.authmesh/<self>/billing-consumer.prod.json>
# If you use the ab0t-quota-go library (Go):
AB0T_QUOTA_BILLING_URL=https://billing.service.ab0t.com
```

Load the key from your secrets manager (never commit it) and send it as
`X-API-Key` on every request to the provider.

### 5. Verify

Call a read endpoint on the provider with the key:

```sh
curl -H "X-API-Key: $BILLING_SERVICE_API_KEY" https://billing.service.ab0t.com/health
```

A 200 with the key (and 401 without) confirms the relationship is live.

## What to do with the key next (routing)

- **Billing / payment / subscriptions** (record usage, quota checks, checkout,
  Customer Portal): load the **`billing-payment-integration`** skill — proxy
  routes, HTML buttons, Stripe Checkout, webhooks. Consumer-account specifics
  for those two are in **`billing-payment-consumer-setup`**.
- **A Go service metering usage / granting credits**: load
  **`ab0t-quota-go-design`** (then `ab0t-quota-go-setup`) — the library reads
  `AB0T_QUOTA_<PROVIDER>_URL` and calls the provider with your key.
- **Other providers** (audit, resource, schema): use the provider's
  `*-service-api-reference` skill with the `X-API-Key` you just minted.

## Reference

- **[references/manual-http-flow.md](references/manual-http-flow.md)** — the two
  raw HTTP calls `connect` automates, for when the binary can't run (other
  languages, no install) or the directory endpoint isn't deployed yet.
- **[references/troubleshooting.md](references/troubleshooting.md)** — 403 on
  mint, "already exists", tier withheld, directory 404, prod guard.
