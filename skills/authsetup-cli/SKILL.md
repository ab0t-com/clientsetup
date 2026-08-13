---
name: authsetup-cli
description: Operate the authsetup CLI (setup-go) — the Auth Mesh client onboarding and management control surface. Use when onboarding a service to the Auth Mesh, setting up auth/login/permissions for a new client service, adding or changing a permission after launch ("new permission doesn't reach existing users", backfill), changing OAuth redirect URIs or hosted-login branding, checking setup health or drift (status/verify), managing the credentials directory or gitignore safety, running setup in CI or from an agent, or migrating from the numbered bash setup scripts. Covers validate/run/status/backfill/info commands, the reconcile state machine, dry-run, multi-env (dev/prod), and day-2 operations.
---

# authsetup — Auth Mesh client setup CLI

One static binary (`authsetup`) that onboards a service to the Auth Mesh and
keeps it converged with its config. Replaces bash scripts 01–09.

Install (no build step):

```bash
curl -fsSL https://raw.githubusercontent.com/ab0t-com/clientsetup/main/install.sh | sh
# or grab a prebuilt binary from the repo's release/ directory
```

## Mental model (read this first)

`config/permissions.json` is the **desired state**. The auth service is the
**actual state**. Every command **reconciles** actual → desired and is safe to
re-run; nothing is "already done, skipping". There is no separate update
command: **to change anything, edit the config and `run` again.**

```
edit config/*.json ──► validate ──► run (--dry-run first) ──► status/run 05 ──► done
       ▲                                                            │
       └──────────────── drift detected / new requirement ◄─────────┘
```

## Quick start (new service)

```bash
export AUTH_SERVICE_URL=https://auth.dev.ab0t.com   # omit for prod
authsetup --config-dir ./config validate
authsetup --config-dir ./config --dry-run run   # plan, mutates nothing
authsetup --config-dir ./config run             # apply
authsetup --config-dir ./config run 06          # e2e proof (throwaway user)
```

Result: service org, permission schema, OAuth client(s), hosted login,
end-users org with auto-join default team. New signups get every
`default_grant: true` permission immediately.

## Day-2 operations (the cases that used to bite)

**Add a new permission for everyone:**
1. Add it to `permissions.json` with `default_grant: true`.
2. `run 01` (catalog) + `run 04` (syncs the shared team + future-workspace template).
3. `workspace-per-user` pattern only: existing per-user workspaces also need
   `backfill` — validate one workspace first, then sweep:
   ```bash
   authsetup backfill --dry-run
   authsetup backfill --only-org <one-workspace-org-id>   # prove it on one user
   authsetup backfill                                     # full sweep
   ```
   Users see changes within ~5 min (permission cache) or on fresh login.

**Change redirect URIs / branding / registration defaults:** edit
`oauth-client.json` / `hosted-login.json`, then `run 02` / `run 03` + `run 04`.

**Land users in their own workspace on login:** set
`registration.default_landing = "workspace"` in `hosted-login.json` (enum
`"workspace"`\|`"parent"`, default `"parent"`), then `run 04`. Requires
`org_structure.pattern = "workspace-per-user"` — there must be a workspace to
land in. Login-only and async-safe (registration always lands on the parent).
To flip it live without re-running setup, `PUT
/organizations/{end_users_org_id}/login-config` is a deep-merge — send just
`{"registration":{"default_landing":"workspace"}}`. Not a CLI flag.

**Check health / drift:** `authsetup status` (read-only). Any reported drift
is fixed by `run`.

**What is configured where?** `authsetup info` (local state + creds dir),
`authsetup status` (server truth).

## Credentials (where secrets live)

Default: `~/.authmesh/<service-id>/` — **outside any git repo by design**.
Override with `--creds-dir` or `AUTHSETUP_CREDS_DIR`. Files are 0600,
bash-kit-compatible, merge-preserving. If you point creds at a path inside a
git repo that is not gitignored, mutating commands stop and ask; for
non-interactive runs pass `--write-gitignore` (appends the entry, recommended)
or `--unsafe-creds-in-repo`. Never commit these files. Every server-touching command also appends a
secret-redacted compliance journal (`journal/run-<ts>.jsonl` in the creds
dir): full request+response JSON per call, tagged by step — the audit trail
for "what did we send and what did the server accept".

## Running from an agent / CI (non-interactive)

```bash
AUTH_SERVICE_URL=... AUTHSETUP_CREDS_DIR=/var/lib/authmesh/svc \
  authsetup --config-dir ./config run
```
- Exit code is the truth: 0 = converged. Non-zero output includes the server's
  error `detail` — read it before retrying.
- Always `--dry-run` first when acting autonomously; apply only when the plan
  matches the intent.
- A lockfile in the creds dir prevents concurrent runs; a stale lock from a
  dead run must be removed manually (the error says the path + pid).
- Validation gates every command. `--skip-validate` exists; do not use it.

## Mesh service-to-service (steps 07/08)

> **NOTE:** step 08's `{service}-api-consumers` org is for OTHER SERVICES (mesh
> consumers), NOT your human end users — those live in the `{service}-users` org
> from step 04. Different orgs, different audiences, different login-config.

**Provide your API to other services:** `run 08` — creates
`{service}-api-consumers` org with tiered teams (Read-Only default +
Standard; customize via `config/api-consumers.json`) and a signup-enabled
login config; prints the consumers' `register_url`.

**Consume another service's API:** drop a `clients.d/<provider>.json` into
your config dir (provider ids + their admin creds path + the permissions you
need + service-account email), then `run 07`. Output:
`<creds>/<provider>-consumer[-dev].json` with the `X-API-Key` value. Re-runs
reuse the key only while its permissions match config; any change mints a
fresh key (revoke the old one after rollover).

## What this tool does NOT do (yet)

- Cross-team consumer self-service (registering with a provider WITHOUT
  their credentials file): use the provider's step-08 `register_url` flow.
- Custom roles in `roles[]` set the *default role name* only — the auth
  service does not yet resolve custom role→permission mappings. Grant
  role-tier perms via the team array (`backfill --extra-perm`) until the
  platform's permission-profile work lands.
- Org structures beyond `flat` and `workspace-per-user` (the other archetypes
  in `config/archetypes/` are server-side roadmap).

## Reference files

- **[control-surface.md](references/control-surface.md)** — full command/flag
  matrix, every config field, credential file shapes, exit codes, state
  machine table. Read when you need an exact flag or file shape.
- Repo docs (github.com/ab0t-com/clientsetup): `README.md` (overview),
  `docs/USAGE.md` (scenario cookbook), `docs/MIGRATION.md` (bash → Go mapping).

## Troubleshooting fast-path

| Symptom | Do |
|---|---|
| `config problem(s)` on any command | fix what it lists; the validator also enforces server rules (service names: no hyphens) |
| `cached credentials no longer valid` | wrong env? check `AUTH_SERVICE_URL` + `info`; creds are per-env (`-dev` suffix) |
| user reports 403 on a new permission | the day-2 flow above (`run 04` + `backfill` for workspaces) |
| `another run holds .setup-go.lock` | previous run died — remove the printed lock file |
| step 06 fails on missing perms | registration→team auto-join broken server-side; check login-config `default_team` via `status` |
| backfill 403 on workspace teams | parent-admin lacks authority on child orgs in this env — escalate to platform team (known watch-item) |
