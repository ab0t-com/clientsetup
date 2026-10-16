---
name: mesh-consumer-account-sop
description: >-
  Give your service its own consumer account and scoped API key on another ab0t mesh service
  (billing, payment, audit, or any partner that publishes tiers), then keep it healthy. Use when a
  service needs to call another mesh service and asks "how do I get a key for <service>", "which tier",
  "authsetup providers", "authsetup connect", "the provider is invitation only", "my key 403s",
  "rotate or revoke a consumer key", "disconnect from a provider", or, for a team that runs several of
  its own services, "consume my own service with clients.d and run 07". Covers choosing a tier,
  previewing and connecting, wiring and verifying the key, moving up a tier, rotation and leaving.
  Procedures live in the Ally SOPs 11 and 14; this skill is the decision guide.
---

# Your service's consumer account on another mesh service

## What this is

A **consumer** is a service that calls another service's API with its own key. You never need the
provider's credentials: the provider publishes **tiers**, you connect, and the auth service mints a key
holding exactly that tier's permissions, so each relationship is narrow, revocable and auditable.

## The picture

```
provider (e.g. billing)
└── billing-api-consumers            ← the provider's "partners" org
    ├── Read-Only Consumers (team)   ← default tier: anyone may join instantly
    ├── <higher tier> (team)         ← the provider moves you here
    └── your consumer account        ← created by `connect`; your key = its tier's permissions, fixed at mint
```

```
Do you also run the provider yourself, in the same organisation, and hold its admin credentials file?
├─ no  (the normal case) → `authsetup connect <provider> --as <you>`                 (SOP 11 steps 1–4)
└─ yes (your own services calling each other) → `config/clients.d/<provider>.json` + `run 07`  (SOP 11 step 6)
Provider shows "closed — invitation only"? → ask it for an invitation; there is no connect line until then.
```

## Do this (the default path)

Write `--env` on every command; `authsetup` defaults to prod.
```sh
authsetup --env dev providers                              # one card per provider: tiers, permissions, the connect line
authsetup --env dev connect billing --as invoicer --dry-run
authsetup --env dev connect billing --as invoicer          # account + key; key saved 0600, never printed
authsetup --env dev status --verify                        # ◐ WIRED → ● LIVE
```
1. Take the tier marked `[default — zero-touch]` unless you know you need more. Re-running `connect` is
   safe (`… key … reused`). Use the same `--as` for every provider: one identity for all your keys.
2. Wire the two values `connect` prints: `<PROVIDER>_SERVICE_URL` and `<PROVIDER>_SERVICE_API_KEY`. The
   key stays in `~/.authmesh/<you>/<provider>-consumer.<env>.json` (field `.api_key.key`); move it into
   your secrets manager without printing it. Off production the URL is left empty on purpose: ask the
   provider for its address on that environment.
3. At runtime send your key as `X-API-Key` (never a user's bearer token), take the customer's `org_id`
   from the validated user token (never from the request), and keep the key server-side. The
   `mesh-service-accounts` skill has a Python client and proxy-route pattern.
4. Need more than the default tier? Tell the provider your consumer account (printed by `connect`) and
   what your service does in one sentence. Once they have moved you:
   `authsetup --env dev connect <provider> --as <you> --tier "<name>"`. A tier that reaches across the
   provider's customers is always invite-only (SOP 12 step 4 is the provider's side). Billing and
   payment specifics: `billing-payment-consumer-setup`.

**The in-house path** (`clients.d` + `run 07`), only when you run both services and hold the provider's
admin credentials file. One file per provider ([the schema](../mesh-service-accounts/references/config-schema.md)), then:
```sh
authsetup --config-dir ./config validate
authsetup --env dev --config-dir ./config --dry-run run 07   # read the plan before anything changes
authsetup --env dev --config-dir ./config run 07
```
`run 07` reconciles **every** file in `clients.d/`, so read the whole plan: a provider you already
connected should show the key as already provisioned, not a create. A key is reused only while its
permission list matches the file; changing the list mints a fresh key (the old one works until you
revoke it). Leave `service_account_password` empty: the tool generates one and keeps it in your
credentials folder. Never commit a password into that file.

## What your customers notice

- Nothing, when it works: your service calls the provider for them. If the provider is unreachable or
  your key is refused, your API should answer `503` (or a clear "try again"), not leak the provider's
  error text and never pretend it succeeded.
- A revoked or rotated key stops working at the provider immediately (`401`); provider SDK caches may
  keep a revoked key working for up to 60 s. Roll the new key out before you revoke the old one.
- Data stays per customer as long as `org_id` always comes from the customer's validated token.

## Common mistakes (and what you will see; full list: SOP 16, *Consumers*)

| you see | do |
|---|---|
| `provider "x" did not grant every permission tier "y" requests — the default tier is zero-touch; …` | connect on the default tier, then ask the provider |
| `tier "x" does not publish its permission set in the directory — …` | same |
| `tier "Pro" not offered — available: …` | pick a listed name, or drop `--tier` |
| `consumer account … already exists but the stored password did not authenticate — pass --email with a fresh address …` | it was created from another machine: use that machine's `~/.authmesh/<you>/`, or `--email` a fresh address |
| `provider "x" has self-serve registration disabled — contact the provider for an invitation` | ask the provider |
| `this auth service has no mesh provider directory yet (GET /mesh/providers → 404) — …` | wrong environment; try another `--env` |
| `○ REGISTERED` in `status` with no key | an interrupted mint; re-run `connect` to adopt it |
| `rate limited by the auth service (~5 requests/min); …` | wait a minute and re-run; it resumes |
| `co-located mode needs the provider's creds file` (`run 07`) | you are not the provider; use `connect` |
| your key `403`s on a call | the tier lacks that permission, or you minted before it was widened: reconnect |

## Check it worked, rotate, leave

```sh
authsetup --env dev status --verify                              # ● LIVE per connection; ⨯ FAILED if a key was revoked
curl -sS -H "X-API-Key: $BILLING_SERVICE_API_KEY" "$BILLING_SERVICE_URL/health"   # 200 with the key, 401 without
authsetup --env dev disconnect billing --as invoicer --dry-run   # rotate / leave: preview what is revoked and archived
authsetup --env dev disconnect billing --as invoicer             # type "billing" to confirm
authsetup --env dev connect    billing --as invoicer             # new key, same tier; re-wire it
```
`disconnect` revokes the key and **moves** the local file to `~/.authmesh/<you>/.archive/`; nothing is
deleted. Never delete `~/.authmesh/<you>/`: it holds every environment's credentials, prod included. A
leaked key: revoke first, then rotate (SOP 14). Still stuck: send `authsetup --env <env> doctor --json`,
`status --json`, the failing output and the latest `~/.authmesh/<you>/journal/*.jsonl` (redacted) to
`platform-team@ab0t.com`; never a credentials file.

## SOPs (in `authmesh/`)

[11 using other services](../../11_sop_system_using_other_services.md) ·
[12 opening your service to others](../../12_sop_system_opening_your_service_to_others.md) ·
[14 keys](../../14_sop_system_keys_rotate_offboard_disconnect.md) ·
[16 troubleshooting](../../16_sop_system_troubleshooting_and_recovery.md) ·
[17 security rules](../../17_sop_system_security_rules.md)
