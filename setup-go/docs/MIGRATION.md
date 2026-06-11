# Migration: bash kit → setup-go

**Audience:** operators currently using the numbered bash scripts.
**Interop guarantee:** both toolchains read and write the same `config/` and
`credentials/` files (same names, shapes, env-suffix rules). You can switch
per-step, in either direction, at any time. setup-go saves are
merge-preserving — it never drops keys it doesn't own.

## Command mapping

| You ran (bash) | You run (Go) | Parity notes |
|---|---|---|
| `./setup run` | `authsetup run` | Go gates on validation; bash didn't |
| `./setup run 04` | `authsetup run 04` | Go syncs team perms every run (bash needed `SYNC_EXISTING=1`) |
| `DRY_RUN=1 ./scripts/04-…` | `authsetup --dry-run run 04` | Go dry-run diffs live server state |
| `./scripts/05-verify-setup.sh` | `authsetup run 05` or `authsetup status` | |
| `./scripts/06-test-end-user.sh` | `authsetup run 06` | Go asserts default_grant ⊆ user perms via admin |
| `./scripts/07-register-consumer.sh` | `authsetup run 07` | reads `<config-dir>/clients.d/*.json`; reuses a saved API key ONLY when permissions match config (fixes the 20260205 stale-key class), mints fresh on drift |
| `./scripts/08-setup-api-consumers.sh` | `authsetup run 08` | tier teams RECONCILED every run; `api-consumers.json` optional (defaults derived in memory, not written to your config dir) |
| `./scripts/09-backfill-workspace-permissions.sh` | `authsetup backfill` | flags: `--only-org`, `--extra-perm` (repeatable), `--dry-run` |
| `./scripts/validate-config.sh` | `authsetup validate` | Go adds the server-side service-name rule |

## Deliberate behavior changes

1. **Step 04 honors your configured default role** (`roles[].default` /
   `end_users.default_role`). The bash script computed it, printed it, and
   then wrote the hardcoded string `member` into login config (bug #9 in
   ticket 20260609). If you RELIED on the silent `member` behavior, set
   `end_users.default_role: "member"` explicitly before migrating.
2. **Reconcile-by-default.** Step 04 brings the default team's permission
   array up to the config's `default_grant` union on every run. Additive only.
3. **Hyphenated `registration.service` is now a validation error**, because
   the auth service registry rejects it (`^[a-z][a-z0-9_]*$`). The bash kit's
   own `permissions.json.example` ships `"my-service"`, which fails this —
   replace the placeholder with your real (hyphen-free) service name.
4. **No `|| true`.** Failures that bash printed-and-continued through now stop
   the run with the server's error detail. Steps that were legitimately
   optional (missing oauth-client.json / hosted-login.json) warn and continue.

## Ported with deliberate deltas (v0.2)

**Step 07 (consumer):** the co-located engine (`register-as-client.sh`) is the
ported mode — it needs the provider's admin credentials file
(`provider.credentials_path` in each `clients.d/*.json`, overridable per the
co-located deployment layout). The cross-team self-service mode
(`consumer-register.sh`, registering against a provider's step-08 consumers
org WITHOUT their credentials) is not yet a Go step — use the provider's
`register_url` (printed by step 08) manually or the bash script.

**Step 07 API-key policy:** bash minted a new key every run; an older helper
silently reused keys with stale permissions (incident 20260205). authsetup
reuses the saved key only when its recorded permission set equals the
config's, and mints a fresh key on any difference (old key stays valid for
rotation overlap — revoke it after rollover).

**Step 08 `api-consumers.json`:** bash auto-generated the file into your
config dir; authsetup derives the same defaults in memory and prints them —
create the file only when you want custom tiers.

**Step 01 API key:** ported (name `{service}-internal`, all permission ids,
rate_limit 100000). Key material can't be re-read from the server, so the
reconcile condition is presence in the credentials file.

**`__09-setup-end-users-org-inherited.sh`** — intentionally not ported: it
was disabled upstream and its model (org-inherited grants) is unimplemented
server-side until the auth roadmap's Tier 2 lands.

## Verification after migrating

```bash
authsetup validate
authsetup --dry-run run          # expect: no planned changes on a healthy setup
authsetup run 05                 # independent checks
authsetup run 06                 # end-to-end throwaway user
```

A healthy migration shows `no changes were needed — server state already
matches config` on the dry run. Any planned change it shows you is real drift
the bash kit's skip-if-exists behavior had been hiding — review each one
before applying.
