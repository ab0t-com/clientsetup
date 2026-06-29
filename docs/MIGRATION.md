# Migration: from the old bash kit

**Audience:** operators coming from an old checkout of the numbered bash scripts
(`./setup` + `scripts/0X-*.sh`). Those scripts no longer ship in the public
`clientsetup` repo — the single static `authsetup` binary is now the only tool.
This guide maps the old commands to their binary equivalents so you can carry an
existing checkout forward.
**File compatibility:** `authsetup` reads and writes the same `config/` files
(same names, shapes, env-suffix rules) the bash kit used, so an existing config
dir migrates as-is. Credentials now land in `~/.authmesh/<service>/` (0600),
outside any repo, with a redacted journal. authsetup saves are
merge-preserving — it never drops keys it doesn't own.

## Before your first run — you won't create a duplicate org

`run 01` only creates a service org if it can't already find one. It finds your
existing setup two ways:

- **Run from your old service directory** (the one with both `config/` and
  `credentials/`) — the binary auto-adopts the bash kit's
  `./credentials/<service>.json`. This is the easy path: `cd` there and run.
- **From anywhere else**, point it at your existing credentials once:
  `authsetup --creds-dir ./credentials --config-dir ./config run`.

If it can neither load cached creds nor adopt the legacy ones, it stops and tells
you the service looks already set up (and how to adopt it) — it never silently
creates a second org. The auth server's duplicate-slug rejection is the backstop.

## Command mapping

Global flags (`--config-dir`, `--dry-run`) go BEFORE the subcommand.

| You ran (bash) | You run (Go) | Parity notes |
|---|---|---|
| `./setup run` | `authsetup --config-dir ./config run` | Go gates on validation; bash didn't |
| `./setup run 04` | `authsetup --config-dir ./config run 04` | Go syncs team perms every run (bash needed `SYNC_EXISTING=1`) |
| `DRY_RUN=1 ./scripts/04-…` | `authsetup --config-dir ./config --dry-run run 04` | Go dry-run diffs live server state |
| `./scripts/05-verify-setup.sh` | `authsetup --config-dir ./config run 05` or `authsetup --config-dir ./config status` | |
| `./scripts/06-test-end-user.sh` | `authsetup --config-dir ./config run 06` | Go asserts default_grant ⊆ user perms via admin |
| `./scripts/07-register-consumer.sh` | `authsetup --config-dir ./config run 07` | reads `<config-dir>/clients.d/*.json`; reuses a saved API key ONLY when permissions match config (fixes the 20260205 stale-key class), mints fresh on drift |
| `./scripts/08-setup-api-consumers.sh` | `authsetup --config-dir ./config run 08` | tier teams RECONCILED every run; `api-consumers.json` optional (defaults derived in memory, not written to your config dir) |
| `./scripts/09-backfill-workspace-permissions.sh` | `authsetup --config-dir ./config backfill` | flags: `--only-org`, `--extra-perm` (repeatable), `--dry-run` |
| `./scripts/validate-config.sh` | `authsetup --config-dir ./config validate` | Go adds the server-side service-name rule |

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
`register_url` (printed by step 08) manually.

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
authsetup --config-dir ./config validate
authsetup --config-dir ./config --dry-run run   # expect: no planned changes on a healthy setup
authsetup --config-dir ./config run 05          # independent checks
authsetup --config-dir ./config run 06          # end-to-end throwaway user
```

A healthy migration shows `no changes were needed — server state already
matches config` on the dry run. Any planned change it shows you is real drift
the bash kit's skip-if-exists behavior had been hiding — review each one
before applying.
