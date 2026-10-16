---
name: mesh-service-accounts
description: >-
  Call another ab0t mesh service from your backend safely: get your service's own scoped API key,
  send it as X-API-Key, take the customer's org from the validated user token, and proxy the result to
  your frontend without leaking errors. Use when a service needs cross-service calls on the mesh
  (billing, payment, audit, a partner's API, or another service of your own), when writing the
  upstream client and proxy routes, when choosing between `authsetup connect` and the in-house
  `clients.d` + `run 07` path, when wiring <PROVIDER>_SERVICE_URL / <PROVIDER>_SERVICE_API_KEY, or when
  debugging 401/403/502/503 on a cross-service call. Procedures: Ally SOPs 11 and 14.
---

# Service-to-service calls on the mesh

## What this is

Each service on the mesh has its own org and its own token audience, so a user's token for your
service is (correctly) refused by every other service. To call another service, your backend uses its
**own** scoped key, minted for that provider, and sends it as `X-API-Key`; the provider checks the key
and its permissions with the auth service on every call.

## The picture

```
browser ──(user token, aud=invoicer)──► your API ── validate token, take org_id from it
                                           │
                                           └──(X-API-Key: your key for billing)──► billing  GET /billing/<org_id>/balance
                                                                                     │ validates the key + its permissions
   browser ◄── your own JSON / generic error ◄──────────────────────────────────────┘
```

| question | answer |
|---|---|
| where does the key come from? | `authsetup --env <env> connect <provider> --as <you>` (normal), or `clients.d/<provider>.json` + `run 07` when you run both services yourself |
| what can it do? | exactly the tier's permissions, fixed when minted; more means the provider moves you and you re-mint |
| where does it live? | `~/.authmesh/<you>/<provider>-consumer.<env>.json` (0600, field `.api_key.key`), then your secrets manager |
| whose data does a call touch? | the `org_id` you put in the path, which must come from the caller's validated token |

## Do this (the default path)

```sh
authsetup --env dev providers
authsetup --env dev connect billing --as invoicer --dry-run
authsetup --env dev connect billing --as invoicer
authsetup --env dev status --verify
```
1. Put the two printed values in your backend env (`BILLING_SERVICE_URL`, `BILLING_SERVICE_API_KEY`).
   Off production the URL is printed empty on purpose: ask the provider for that environment's address.
2. Write one small client per provider: [references/client-patterns.md](references/client-patterns.md).
3. Expose only what your frontend needs through your own routes:
   [references/proxy-routes.md](references/proxy-routes.md).
4. Running both services yourself? Declare the relationship in `config/clients.d/<provider>.json`
   ([references/config-schema.md](references/config-schema.md)) and
   `authsetup --env dev --config-dir ./config --dry-run run 07`, then the same without `--dry-run`.

The decision guide (tiers, upgrades, the in-house path, rotation) is `mesh-consumer-account-sop`;
billing and payment specifics are `billing-payment-consumer-setup`.

## The rules, every call

- **Never forward a user's bearer token** to another service: wrong audience, wrong permissions.
- **Take `org_id` from the validated token**, never from the URL, the body or a header the browser sets.
- **Keep the key server-side**: never in a frontend bundle, a log line, a ticket or a chat.
- **Mask upstream errors**: log the provider's detail server-side; return a generic message.
- **Fail closed**: if the provider or the auth service cannot answer, return `503`, never a success.

## What your customers notice

- Nothing about keys. They see your pages; your backend fetches their data with your key, scoped to
  their org.
- When a provider is down they get your `503` / "try again", not the provider's internals. A
  permission problem on *your* key is your bug: return `502` and fix the tier, do not show a `403` that
  makes the customer think they lack access.

## Common mistakes (and what you will see)

| mistake | what you see | fix |
|---|---|---|
| key not set, or the wrong provider's key | `401` from the provider | the right `<PROVIDER>_SERVICE_API_KEY`; keys are per provider |
| the tier lacks a permission | `403` naming the missing permission | ask the provider, then `connect --tier "<name>"` |
| acting on a customer's org without the cross-customer tier | `403 … Access denied - different organization` (billing) | SOP 11 step 5 |
| `org_id` taken from the URL | a customer can read another customer's data | take it from the token |
| structlog kwargs on a stdlib logger | `TypeError: Logger._log() got an unexpected keyword argument` | see the logger note in client-patterns |
| container calls `localhost` | `503` "unreachable" from your client | use the address reachable from the container |

## Check it worked

```sh
authsetup --env dev status --verify                                             # ● LIVE per connection
curl -sS -H "X-API-Key: $BILLING_SERVICE_API_KEY" "$BILLING_SERVICE_URL/health"  # 200 with the key, 401 without
```
Then call one of your proxy routes with a real user token and expect `200`. Rotate or leave a provider
with `disconnect` (SOP 14); never delete `~/.authmesh/<you>/`. Still stuck: `authsetup --env dev doctor
--json`, `status --json` and the failing output to `platform-team@ab0t.com` (never a key).

## SOPs (in `authmesh/`)

[06 wire it into your app](../../06_sop_system_wire_it_into_your_app.md) ·
[11 using other services](../../11_sop_system_using_other_services.md) ·
[14 keys](../../14_sop_system_keys_rotate_offboard_disconnect.md) ·
[16 troubleshooting](../../16_sop_system_troubleshooting_and_recovery.md) ·
[17 security rules](../../17_sop_system_security_rules.md)
