---
name: billing-payment-consumer-setup
description: Mint a service's billing (8002) and payment (8005) mesh consumer accounts using the authsetup Go binary. Use when a mesh service needs to call billing and/or payment on behalf of its users (record usage, check quota, create checkout sessions, manage subscriptions) and must obtain its own scoped X-API-Key(s) via authsetup run 07 — including the billing-vs-payment permission-set differences, the seed-to-adopt trick for an existing consumer, and the post-reset membership-gap gotcha that makes run 07 falsely plan a CREATE. This is the billing/payment-specific, Go-binary-specific how-to; for the general consumer mechanism see mesh-service-accounts, and for the runtime proxy/HTML/Stripe wiring see billing-payment-integration.
---

# Billing / Payment Mesh Consumer Setup (via authsetup)

> **In this skill "consumer" = a SERVICE calling another service — NOT your product's human end users.** Human end users live in the `{service}-users` org (see the `auth-mesh-setup` skill); mesh consumers are other services and live in the `{service}-api-consumers` org.

Mint a service's **billing** and **payment** consumer accounts — the scoped
`X-API-Key`s that let it call billing-service (8002) and payment-service (8005)
on behalf of its users — using the `authsetup` Go binary.

This skill is the **billing/payment + Go-binary specific** layer. It does NOT
duplicate:
- **`mesh-service-accounts`** — the general consumer mechanism (`clients.d`
  schema, what `run 07`/`run 08` do, X-API-Key rules). Read it first if you're
  new to mesh consumers.
- **`billing-payment-integration`** — the runtime side (proxy routes, pricing
  buttons, Stripe Checkout/Portal, webhook forwarding) once you HAVE the keys.
- **`authsetup-cli`** — the binary's full command surface / reconcile model.

Read those for the general case; read THIS for the billing/payment specifics.

## When to use

A service needs to charge/meter its users → it must be a **consumer** of
billing and/or payment. Sandbox-platform is the reference: it has BOTH
(`~/.authmesh/sandbox-platform/{billing,payment}-consumer.prod.json`,
`clients.d/{billing,payment}.json`). Connect had only billing — this is the
skill for closing that kind of gap.

## The mechanism in one line

Drop a `clients.d/<provider>.json` into the service's config dir, then
`authsetup ... run 07`. It logs in as the **provider admin**, creates a
customer **sub-org** + **service account** under the provider, and mints a
scoped **`X-API-Key`** → `~/.authmesh/<svc>/<provider>-consumer.prod.json`
(0600). Idempotent: re-runs reuse the key iff config perms match.

## Step 1 — author `clients.d/{billing,payment}.json`

Config dir is `<svc>/output/setup/config/clients.d/` (the **new** authsetup
location — NOT `setup/scripts/service-client-setup/clients.d/`, which `run 07`
never reads). Model on
`resource/output/sandbox-platform/setup/config/clients.d/{billing,payment}.json`.

Four blocks (see `mesh-service-accounts` → references/config-schema for the full
field list). Billing example skeleton:

```jsonc
{
  "provider": {
    "service_id": "billing",                                  // or "payment"
    "service_name": "Billing Service",
    "credentials_path": "<PROVIDER ADMIN CREDS>",             // see Step 2
    "service_url": "http://localhost:8002"                    // 8005 for payment; informational
  },
  "client": {
    "service_id": "<consumer-id>",                            // STABLE identity — changing it forces a re-mint
    "service_name": "<Consumer>",
    "customer_org_name": "<Consumer> - Billing Customer",     // "... - Payment Customer" for payment
    "customer_org_slug": "billing-customer-<consumer>",       // "payment-customer-<consumer>"
    "service_account_email": "<consumer>@billing.customers",
    "service_account_password": "<SECRET — never print>"
  },
  "permissions": [ /* see Step 3 */ ],
  "api_key": {
    "name": "<consumer>-billing-backend",
    "rate_limit": 10000,
    "metadata_purpose": "Backend access to record usage / reserve funds / proxy billing on behalf of users"
  }
}
```

**Identity consistency rule**: keep `client.service_id` the **same across
billing and payment** so both consumers sit under one identity (e.g. connect's
billing consumer is `integration-service`; its payment consumer should mirror
that, not diverge to `connect-service`, until a coordinated rename). A mismatch
here is exactly the `connect` vs `connect-service` split that bit the audit mint.

## Step 2 — provider admin credentials path

`run 07` needs to log in AS the provider's admin to create the sub-org. Point
`provider.credentials_path` at a **prod** provider cred:
- Billing: `billing/output/setup/credentials/billing.json` (the prod/org-B file
  — do NOT feed a `-dev.json` or an archived org-A twin; run 07 uses the
  file's `Organization.ID` as the parent).
- Payment: the adopted provider cred, e.g. `~/.authmesh/payment/payment.prod.json`.

## Step 3 — permissions (billing vs payment differ)

Scope to what the consumer actually does. Reference sets (from sandbox):

| | **Billing** | **Payment** |
|---|---|---|
| read | `billing.read`, `.read.accounts/.transactions/.usage/.reports/.reservations` | `payment.read`, `.read.payments/.payment_methods/.invoices/.subscriptions/.plans/.products/.prices` |
| write | `billing.write.reservations/.usage/.transactions/.refunds` | `payment.write`, `.write.payments/.subscriptions/.payment_methods` |
| create | — | `payment.create.plans/.payments/.subscriptions` |
| admin | `billing.admin` | `payment.admin` |
| **cross** | **`billing.cross_tenant`** | **`payment.cross_org`** |

Two things to get right:
1. **The cross-permission name differs**: billing = `cross_tenant`, payment =
   `cross_org`. A gateway serving many user orgs through one key MUST have it,
   or every proxied call 403s.
2. **Only grant what you proxy.** A meter-only consumer (like connect's billing:
   `billing.read`, `.read.accounts`, `.read.usage`, `.write.usage`,
   `.cross_tenant`) needs no `*.admin`. Include `payment.admin` only if the
   service manages plans/products itself; drop it if it merely proxies user
   payment ops.

## Step 4 — seed-to-adopt (for an EXISTING consumer)

If the consumer already exists (a real sub-org + live key from a previous mint)
you want `run 07` to **adopt** it, not create a duplicate. Hand-seed the saved
cred first so the tool recognizes it:

```
~/.authmesh/<svc>/<provider>-consumer.prod.json   # seed with the existing key_id + SA + org
```

`run 07` reuses the key iff a saved cred exists AND its recorded perms == config
perms. A **net-new** consumer (no prior sub-org) needs no seed — it's a clean
create (e.g. connect→payment: connect has no payment sub-org, so no seed, no
gate).

## Step 5 — dry-run, then run

```bash
AUTHSETUP=~/.local/bin/authsetup   # or shared/ab0t-setup-go/setup-go/release/authsetup-linux-amd64
CFG=<svc>/output/setup/config
CREDS=~/.authmesh/<svc>

$AUTHSETUP --env prod --config-dir "$CFG" validate
$AUTHSETUP --env prod --config-dir "$CFG" --creds-dir "$CREDS" --dry-run run 07
#   EXPECT: "reuse existing / adopt" for a known consumer, OR exactly the
#           listed create for a net-new one. Anything else → ABORT (see gotcha).
$AUTHSETUP --env prod --config-dir "$CFG" --creds-dir "$CREDS" run 07
```

Rate limit: auth is 5/min — a mint is ~5 calls; run it in one clean window.
`run 07` reconciles EVERY `clients.d/*.json`; use a `.hold` suffix on files you
don't want touched, or run per-consumer.

## Step 6 — validate + wire

```bash
# never print the key body; validate returns perms
POST /auth/validate-api-key {api_key: <from ~/.authmesh/<svc>/<provider>-consumer.prod.json>}
#   → valid: true, permissions: <your set>
```

Then wire into the service env (announce name/file/line; **deploy = owner**):
```
BILLING_SERVICE_URL=...     BILLING_SERVICE_API_KEY=<X-API-Key>
PAYMENT_SERVICE_URL=...     PAYMENT_SERVICE_API_KEY=<X-API-Key>
```
Runtime sends the key as **`X-API-Key`** (never the user JWT); inject `org_id`
from the validated JWT. Runtime proxy/HTML/Stripe wiring →
`billing-payment-integration`.

## Gotcha — the post-reset membership gap (adopt falsely plans a CREATE)

Observed on connect's billing and resource's billing adopt (migration worklog
lines 62-66, 110-113). Symptom:

```
--dry-run run 07 → "would: create customer sub-org '<X> - Billing Customer'"
```
…even though the sub-org and a live key already exist.

**Cause**: `run 07` adopts by scanning the **provider admin's**
`GET /users/me/organizations`. If the sub-org was created (pre-reset) by a
now-dead admin generation, the *current* provider admin is not a member, so
`MyOrgs` can't see it → the tool thinks it must create one.

**Do NOT** let it create (that duplicates the consumer). ABORT the real run.

**Repair (owner-gated — a permission grant on live prod)**: the sub-org's own
service account (already admin of it) invites the current provider admin:
`POST /organizations/<sub-org>/invite {email: <provider>-admin@ab0t.com, role: admin}`.
Then re-dry-run → it flips to "sub-org exists + key already provisioned". This
is exactly the membership `run 07` establishes on a fresh mint; the additive
invite tolerates 409/400. The live runtime key is untouched throughout — only
the *adopt* is blocked, nothing is broken.

Net-new consumers (no prior sub-org) never hit this.

## Verify checklist

- [ ] `~/.authmesh/<svc>/<provider>-consumer.prod.json` exists, 0600.
- [ ] `POST /auth/validate-api-key` → valid, perms == config.
- [ ] Pre-existing consumers' key_ids UNCHANGED (diff before/after — the whole
      migration's non-destructive invariant).
- [ ] Env staged in `.env.production` + template; owner deploys.

## References
- `mesh-service-accounts` — general consumer mechanism + references/*.md.
- `billing-payment-integration` — runtime proxy routes, Stripe, webhooks.
- `authsetup-cli` — full binary surface + reconcile model.
- Reference configs: `resource/output/sandbox-platform/setup/config/clients.d/{billing,payment}.json`.
- Migration ticket: `~/infra/infra/ops/tickets/20260703_mesh_client_authsetup_migration/` (worklog = the gotcha evidence).
- Ticket c3a8: `intergration/output/tickets/open/2026-07-03-c3a8-connect-billing-payment-consumer-accounts/{TICKET,DISCUSSION}.md`.
