---
name: mesh-consumer-account-sop
description: Operational SOP + field playbook for provisioning, adopting, or migrating a service's mesh CONSUMER accounts (billing / payment / audit / any provider) with the authsetup Go binary. Use when a mesh service needs its own scoped X-API-Key to call another service — to decide new-mint vs adopt-existing vs migrate, author clients.d/<provider>.json to schema, run `authsetup run 07` SAFELY (the isolate-not-abort .hold trick, the post-reset membership-gap gotcha that fakes a CREATE, seed-to-adopt for existing consumers, 5/min rate-limit pacing), verify existing keys are UNCHANGED, and wire the key into the service's prod env. This is the decision-tree + hard-won-gotchas layer; for the general mechanism see `mesh-service-accounts`, billing/payment perm specifics see `billing-payment-consumer-setup`, service onboarding (run 01-08) see `auth-mesh-setup`, CLI flags see `authsetup-cli`.
---

# Mesh Consumer Account SOP

Give a service its own **scoped API key** to call another mesh service, using the `authsetup` Go binary (`~/.local/bin/authsetup`). One `clients.d/<provider>.json` per provider → `authsetup run 07` → a `<consumer>-consumer.prod.json` cred (0600, in `~/.authmesh/<consumer>/`) holding an `X-API-Key`.

## 0. Decide the operation FIRST (the fork that prevents damage)
```
Does the consumer ALREADY have a live key for this provider?
├─ NO  → NEW MINT   (net-new: run 07 creates sub-org + SA + key). Cleanest.
└─ YES → is its cred already in ~/.authmesh/<consumer>/<provider>-consumer.prod.json ?
         ├─ YES → ADOPT   (run 07 reuses the key IF recorded perms == config; else mints fresh)
         └─ NO  → SEED-TO-ADOPT   (copy the existing cred into ~/.authmesh first, THEN run 07 — or it creates a DUPLICATE)
```
Never run against prod without knowing which branch you're in. A wrong branch = duplicate org or a needless key rotation.

## 1. Author `clients.d/<provider>.json` (the schema — get this exact)
Lives in `<consumer>/output/setup/config/clients.d/`. `run 07` auto-discovers ALL `*.json` there.
```json
{
  "provider": {
    "service_id": "billing",                                  // provider's service.id (its permissions.json)
    "service_name": "Billing Service",
    "credentials_path": "/abs/path/to/~/.authmesh/billing/billing.prod.json",  // ABSOLUTE (no ~ — tilde-expansion risk); provider admin creds
    "service_url": "http://billing-service-prod:8002"         // recorded only; the INTERNAL url the consumer calls
  },
  "client": {
    "service_id": "integration-service",                      // the CONSUMER's identity — MUST match its other consumer creds
    "service_name": "Integration Service",
    "customer_org_name": "Integration Service - Billing Customer",       // "{Consumer} - {Provider} Customer"
    "customer_org_slug": "billing-customer-integration-service",         // "{provider}-customer-{consumer}" — unique across auth
    "service_account_email": "mike+integration-billing@ab0t.com",        // convention "{consumer}@{provider}.customers" OR mike+... ; NOT a real inbox
    "service_account_password": "<strong, generated — never commit-echoed>"  // used only at registration
  },
  "permissions": ["billing.read","billing.write.usage","billing.cross_tenant"],  // must exist in the provider's permissions.json
  "api_key": { "name": "integration-service-billing-backend", "rate_limit": 10000,
               "metadata_purpose": "Backend API access ..." }
}
```
**Permission rules by provider (memorize):**
- **billing** → needs `billing.cross_tenant` (a gateway records usage under the END-USER's org, not its own).
- **payment** → needs `payment.cross_org`. Omit `payment.admin` unless the consumer actually administers payment (a proxy does not).
- **audit** → `audit.events.create` only; NO cross_tenant (ingest gates on suspension, not org).
- **Identity consistency**: a consumer's billing + payment + audit configs must ALL use the same `client.service_id` (e.g. all `integration-service`), or you fragment its identity across sub-orgs.

## 2. Validate → DRY-RUN GATE (never skip)
```
AS=~/.local/bin/authsetup; CFG=<consumer>/output/setup/config; CR=~/.authmesh/<consumer>
$AS --env prod --config-dir $CFG --creds-dir $CR validate
$AS --env prod --config-dir $CFG --creds-dir $CR --dry-run run 07
```
Read the plan. For the provider you're adding: **exactly** `create sub-org + SA + key` (new mint) OR `key already provisioned (id …)` (adopt). For every OTHER provider already set up: it MUST say adopt/reuse. **If an already-live provider shows CREATE → do NOT proceed blindly (see gotcha B).**

## 3. Run + validate + wire
```
$AS --env prod --config-dir $CFG --creds-dir $CR run 07     # mints/reconciles
# key lands: $CR/<provider>-consumer.prod.json
curl -s -X POST https://auth.service.ab0t.com/auth/validate-api-key -H 'Content-Type: application/json' \
     -d "{\"api_key\":\"$(python3 -c 'import json;print(json.load(open("'$CR'/<provider>-consumer.prod.json"))["api_key"]["key"])')\"}"
# → valid:true, perms == config (DON'T print the key)
```
Wire into the consumer's `production/.env.production` + `.env.production.template`: `<PROVIDER>_SERVICE_API_KEY=<key>` + `<PROVIDER>_SERVICE_URL=<internal url>`. Copy the value from the cred file (never echo). **Deploy (distribute + recreate container) = OWNER.**

## 4. Field playbook — the gotchas that bite (all learned live)
- **A. `run 07` reconciles ALL `clients.d/*.json` at once** — not just the one you added. So a broken/gated OTHER provider can cause collateral mints. **Isolate**: temporarily rename the others (`mv billing.json billing.json.hold`), dry-run to confirm 1 change, `run 07`, then restore (`mv billing.json.hold billing.json`). Never leave them held.
- **B. Post-reset membership gap → FALSE "CREATE".** If a provider was reset, its current admin may have lost membership of a *pre-reset* consumer sub-org. `run 07` finds sub-orgs via the provider admin's MyOrgs, can't see it, and plans a spurious **CREATE** (which would duplicate the sub-org + rotate the key). This is NOT a seed error. **Fix = one additive invite** (the sub-org's own SA invites the provider admin back as admin), THEN adopt. Until fixed, **isolate that provider (gotcha A) — do not let it CREATE.**
- **C. Seed-to-adopt**: `authsetup migrate` imports ONLY the service cred. For an existing CONSUMER key to be adopted (not re-minted), its cred must be in `~/.authmesh/<consumer>/<provider>-consumer.prod.json` first. If the only copy is in `setup/credentials/`, copy it (as `.prod.json`) before `run 07`.
- **D. Reuse is conditional**: `run 07` reuses a saved key ONLY when its recorded permission set == config. Any perm drift → fresh key (old stays valid; revoke after rollover). So don't edit perms unless you mean to rotate.
- **E. Rate limit = 5 requests/minute** on auth. A mint is ~5 calls; run in one clean window. On HTTP 429, cool down ~65s and re-run (state reconciles). Don't hammer — you'll get partial failures mid-sequence.
- **F. Always prove no collateral**: after `run 07`, confirm every OTHER consumer key's `key_id` (and ideally sha256) is UNCHANGED vs before. The mint must only ADD.
- **G. Absolute `credentials_path`** (not `~`) in clients.d — dodges tilde-expansion, matches existing configs.
- **H. Use the INSTALLED binary** (`~/.local/bin/authsetup`, via the repo `install.sh`) — never the raw `setup-go/release/` binary.

## 5. Verify it's really connected
`~/.authmesh/<consumer>/` shows the `<provider>-consumer.prod.json`; the key `validate`s with the right perms; env has `<PROVIDER>_SERVICE_API_KEY`+`_URL`; and (post-deploy) a real consumer→provider call returns 2xx with `X-API-Key`. For payment/quota runtime wiring (Stripe, ab0t-quota-go), see the RUNBOOK + `billing-payment-integration`.

## Related
- `mesh-service-accounts` — general consumer registration + `run 07` internals.
- `billing-payment-consumer-setup` — billing/payment perm sets + the drop-in clients.
- `auth-mesh-setup` / `authsetup-cli` — full service onboarding (run 01-08) + CLI flags.
- RUNBOOK: `shared/ab0t-quota-go/RUNBOOK_connect_service_to_billing_payment_quota_20260703.md`.
- Reference incident/learnings: `ops/tickets/20260703_mesh_client_authsetup_migration/` (the whole migration + `worklog_20260703_fable5_migration.md`).
