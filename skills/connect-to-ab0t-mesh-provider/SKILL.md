---
name: connect-to-ab0t-mesh-provider
description: >-
  Connect a service (or agent) to an ab0t mesh provider with the authsetup CLI: discover providers,
  self-register as a consumer, mint a scoped API key, and wire it in, with no provider credentials and
  no config files. Use when a service needs to CALL another mesh service (billing, payment, audit, a
  partner's API) and asks "how do I get an API key for <service>", "connect to the mesh", "authsetup
  providers", "authsetup connect", which tier to choose, why a minted key 403s on a permission, or what
  to do with the key next. For the decision guide (tiers, upgrades, rotation, the in-house clients.d
  path) see mesh-consumer-account-sop.
---

# Connect to a mesh provider

## What this is

A provider publishes **tiers** of access in the mesh directory; you connect in one command and get your
own key holding exactly one tier's permissions. You never see the provider's credentials, and the
provider never provisions anything per customer.

## The picture

```
authsetup --env dev providers ──► directory: billing, payment, … each with tiers and a connect line
authsetup --env dev connect billing --as invoicer
   1. finds the provider (works for unlisted providers too, given the id)
   2. picks the tier (--tier "<name>", else the default)
   3. registers a service account in billing-api-consumers (password generated and kept for you)
   4. mints a key holding exactly the tier's permissions (the auth service refuses anything more)
   5. saves it 0600 to ~/.authmesh/invoicer/billing-consumer.<env>.json — never printed
   6. prints the env lines to wire
```

## Do this (the default path)

```sh
curl -fsSL https://raw.githubusercontent.com/ab0t-com/clientsetup/main/install.sh | sh
authsetup version
authsetup --env dev providers                       # human-readable cards; --json prints one JSON document
authsetup --env dev connect billing --as invoicer --dry-run
authsetup --env dev connect billing --as invoicer
authsetup --env dev status --verify                 # ◐ WIRED → ● LIVE
```
Read each card for the provider id, its tiers and their permissions; the tier marked
`[default — zero-touch]` is the one anyone may join instantly. `--as` names your identity (defaults to
your config's `service.id`, else `authmesh-consumer`); use the same one for every provider. `--email`
chooses the consumer account's address.

Then wire the two lines `connect` prints. On production, for billing:
```
BILLING_SERVICE_URL=https://billing.service.ab0t.com
BILLING_SERVICE_API_KEY=<read .api_key.key from ~/.authmesh/invoicer/billing-consumer.prod.json>
```
Off production the URL is left empty on purpose (`# BILLING_SERVICE_URL: not published for this
environment — ask the provider for its URL`). Load the key from your secrets manager and send it as
`X-API-Key` on every call to the provider. Prod: the same commands with `--env prod`.

A five-minute walkthrough for humans is `QUICKSTART.md` in `https://github.com/ab0t-com/clientsetup`.

## What to do with the key next

- **Billing and payment** (metering, balances, plans, checkout, the customer portal):
  `billing-payment-consumer-setup`, then the billing-quota bot (Penny) and its SOPs.
- **Any provider from your own backend code**: `mesh-service-accounts` (client and proxy-route patterns).
- **A higher tier, rotation, leaving**: `mesh-consumer-account-sop` and Ally SOP 14.
- **The provider's API itself**: its `/openapi.json`.

## What your customers notice

Nothing, when it works: your backend calls the provider for them, scoped to their org (take `org_id`
from their validated token). If the provider cannot be reached, your API should answer `503`, never
fake a success, and never pass the provider's error text to the browser.

## Common mistakes (and what you will see)

| you see | it means | do |
|---|---|---|
| `this auth service has no mesh provider directory yet (GET /mesh/providers → 404) — …` | not on that environment | another `--env`, or the manual flow |
| `no mesh provider "biling"` | typo or wrong environment | `authsetup --env dev providers` |
| `tier "Pro" not offered — available: …` | wrong tier name | pick a listed one, or drop `--tier` |
| `provider "billing" did not grant every permission tier "Standard Consumers" requests — the default tier is zero-touch; …` | that tier needs the provider's approval | connect on the default tier, ask the provider, then `--tier` |
| `tier "Integrations" does not publish its permission set in the directory — …` | same | same |
| `consumer account … already exists but the stored password did not authenticate — pass --email with a fresh address …` | created from another machine | that machine's `~/.authmesh/<you>/`, or `--email` |
| `provider "x" has self-serve registration disabled` / `closed — invitation only` | sign-up is off | ask the provider for an invitation |
| `refusing to mutate PRODUCTION (…) without an explicit target — …` | no `--env` | add `--env dev` (or `--env prod` deliberately) |
| `creds dir … is inside a git repo and not gitignored; …` | your credentials would land in a repository | `--write-gitignore`, or keep the default `~/.authmesh/` |

More: [references/troubleshooting.md](references/troubleshooting.md) and Ally SOP 16 (*Consumers*).

## Check it worked

```sh
authsetup --env dev status --verify
curl -sS -H "X-API-Key: $BILLING_SERVICE_API_KEY" "$BILLING_SERVICE_URL/health"   # 200 with the key, 401 without
```
Still stuck: `authsetup --env dev doctor --json`, `status --json`, the failing output and the latest
`~/.authmesh/<you>/journal/*.jsonl` (redacted) to `platform-team@ab0t.com`; never the key.

## Reference

- [references/manual-http-flow.md](references/manual-http-flow.md): the HTTP calls `connect`
  automates, for a client that cannot run the binary.
- [references/troubleshooting.md](references/troubleshooting.md): `providers` / `connect` problems.
- Ally SOPs (in `authmesh/`): [11 using other services](../../11_sop_system_using_other_services.md) ·
  [14 keys](../../14_sop_system_keys_rotate_offboard_disconnect.md) ·
  [16 troubleshooting](../../16_sop_system_troubleshooting_and_recovery.md).
