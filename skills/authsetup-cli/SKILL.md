---
name: authsetup-cli
description: Operate the authsetup CLI — the Auth Mesh client onboarding and management control surface. Use when onboarding a service to the Auth Mesh, setting up auth/login/permissions for a new client service, adding or changing a permission after launch ("new permission doesn't reach existing users", backfill), changing OAuth redirect URIs or hosted-login branding, checking setup health or drift (status/verify), managing the credentials directory or gitignore safety, running setup in CI or from an agent, or migrating from the numbered bash setup scripts. Covers validate/run/status/backfill/info commands, the reconcile state machine, dry-run, multi-env (dev/prod), and day-2 operations.
---

# authsetup — Auth Mesh client setup CLI

One static binary (`authsetup`) that onboards a service to the Auth Mesh and
keeps it converged with its config. (It replaces the older numbered bash setup scripts.)

Install (no build step):

```bash
curl -fsSL https://raw.githubusercontent.com/ab0t-com/clientsetup/main/install.sh | sh
authsetup version          # keep it current: authsetup update --check, then authsetup update
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

## Quick start — the newcomer path (0.5.22)

```bash
authsetup init --publish                      # a few questions → config/ written + validated (never overwrites)
authsetup --env dev up --dry-run              # the plan in plain words: your app / your users / your partners
authsetup --env dev up --yes                  # apply (only after the human said yes to that plan)
authsetup --env dev settings --env-file .env  # app values into .env (0600 managed block; the key is never printed)
authsetup --env dev snippet login > login.html  # sign-in block, token standard (authFetch / getValidToken / session_expired)
authsetup --env dev login-url --check         # the users' hosted sign-in page, checked
```
`up` never guesses the environment (no `--env`/`use-env` → it asks on a terminal, refuses in a script) and
refuses to apply without `--yes` when stdin is not a terminal. An unchanged re-run ends "already matches
your config". `run [step ...]` below is the unchanged expert path.

## Quick start — the expert path (numbered pipeline)

```bash
authsetup --env dev --config-dir ./config validate
authsetup --env dev --config-dir ./config --dry-run run   # plan, mutates nothing
authsetup --env dev --config-dir ./config run             # apply
authsetup --env dev --config-dir ./config run 06          # e2e proof (a throwaway user, removed afterwards)
```
Always pass `--env` (`dev` first, `prod` when you mean it); copy NEXT lines as printed — they repeat it.

Result: service org, permission schema, OAuth client(s), hosted login,
end-users org with auto-join default team. New signups get every
`default_grant: true` permission immediately.

## Day-2 operations (the cases that used to bite)

**Add a new permission for everyone:**
1. Add it to `permissions.json` with `default_grant: true`.
2. `authsetup --env dev --config-dir ./config up` (or `run 01 04`: catalog + the shared team and the
   future-workspace template).
3. `workspace-per-user` pattern only: existing per-user workspaces also need
   `backfill` — validate one workspace first, then sweep:
   ```bash
   authsetup --env dev --config-dir ./config --dry-run backfill
   authsetup --env dev --config-dir ./config backfill --only-org <one-workspace-org-id>   # prove it on one user
   authsetup --env dev --config-dir ./config backfill                                     # full sweep
   ```
   Users see changes within ~5 min (permission cache) or on fresh login.

**Change redirect URIs / branding / registration defaults:** edit
`oauth-client.json` / `hosted-login.json`, then `authsetup --env dev --config-dir ./config up`
(experts: `run 02` / `run 03` + `run 04`).

**Land users in their own workspace on login:** set
`registration.default_landing = "workspace"` in `hosted-login.json` (enum
`"workspace"`\|`"parent"`, default `"parent"`), then `run 04`. Requires
`org_structure.pattern = "workspace-per-user"` — there must be a workspace to
land in. Login-only and async-safe (registration always lands on the parent).
Change it in the file, not on the server: the file wins on every run.

**Check health / drift:** `authsetup --env dev --config-dir ./config status` (read-only; exit 3 on
drift). Any reported drift is fixed by `up` / `run`.

**What is configured where?** `authsetup --env dev info` (local state + creds dir),
`authsetup --env dev --config-dir ./config status` (server truth), `authsetup --env dev whois <id>`.

## Credentials (where secrets live)

Default: `~/.authmesh/<service-id>/` — **outside any git repo by design**.
Override with `--creds-dir` or `AUTHSETUP_CREDS_DIR`. Files are 0600,
bash-kit-compatible, merge-preserving. If you point creds at a path inside a
git repo that is not gitignored, mutating commands stop and ask; for
non-interactive runs pass `--write-gitignore` (appends the entry, recommended)
or `--unsafe-creds-in-repo`. Never commit these files, and never delete the directory: it holds every
environment's credentials, prod included (move one named file aside at most). Every server-touching command also appends a
secret-redacted compliance journal (`journal/run-<ts>.jsonl` in the creds
dir): full request+response JSON per call, tagged by step — the audit trail
for "what did we send and what did the server accept".

## Running from an agent / CI (non-interactive)

```bash
AUTHSETUP_CREDS_DIR=/var/lib/authmesh/svc \
  authsetup --env dev --config-dir ./config run
```
- Exit code is the truth: `0` converged · `1` failed · `2` unknown flag · `3` drift (`status`) · `4` cannot
  repair (needs a human). Failure output explains what happened and what to do — read it before retrying;
  the NEXT block prints the exact command that resumes from the failed step.
- Always `--dry-run` first when acting autonomously; apply only when the plan
  matches the intent. Every `would:` line is counted in the plan total.
- **Schema ownership:** "permission schema name … is taken" → choose a different `registration.service`
  (or `--creds-dir` the setup that owns it); "… no owner recorded" → ask the auth team to record your
  service org as its owner (re-running does not help). Both stop before anything is created on a first run.
- A lockfile in the creds dir prevents concurrent runs; the error says whether
  the locking run is still alive — remove the file only when it says stale.
- Validation gates every command. `--skip-validate` exists; do not use it.

## Mesh service-to-service (steps 07/08)

> **NOTE:** step 08's `{service}-api-consumers` org is for OTHER SERVICES (mesh
> consumers), NOT your human end users — those live in the `{service}-users` org
> from step 04. Different orgs, different audiences, different login-config.

**Provide your API to other services:** `run 08` — creates
`{service}-api-consumers` org with tiered teams (Read-Only default +
Standard; customize via `config/api-consumers.json`) and a login config, and
lists you in the mesh directory. Self-serve sign-up for consumers is OFF by
default (listed but closed — consumers need an invitation); set
`registration.signup_enabled: true` in `api-consumers.json` to open it.

**Consume another service's API:** `authsetup --env dev connect <provider> --as <you>` (self-serve, no
provider credentials; `authsetup --env dev providers` lists who accepts consumers). Only when you also
run the provider and hold its admin credentials file: drop a `clients.d/<provider>.json` into your
config dir (provider ids + their admin creds path + the permissions you need + service-account email),
then `run 07`. Output:
`<creds>/<provider>-consumer.<env>.json` with the `X-API-Key` value. Re-runs
reuse the key only while its permissions match config; any change mints a
fresh key (revoke the old one after rollover).

## App-to-app connections (MAP, 0.5.23)

`connection create|list|revoke` — NOT `connect` (that is consumer sign-up). A
connection = "app A may reach resource B for the people of org O, within these
scopes", approved by an admin of O (your service admin signs in; O = `--org`,
else your users org). `--consent admin|user` is REQUIRED and never defaulted.
The app must be a confidential client with a registered scope ceiling;
`--to` is the resource's service_audience. Auth records it now; the per-person
token exchange that uses it is a later auth release. `authsetup connection --help`.

## What this tool does NOT do (yet)

- Custom roles in `roles[]` set the *default role name* only — the auth
  service does not yet resolve custom role→permission mappings. Grant
  role-tier perms via the team array (`backfill --extra-perm`) until the
  platform's permission-profile work lands.
- Org structures beyond `flat` and `workspace-per-user`.

## Reference files

- **[control-surface.md](references/control-surface.md)** — full command/flag
  matrix, every config field, credential file shapes, exit codes, state
  machine table. Read when you need an exact flag or file shape.
- Repo docs (github.com/ab0t-com/clientsetup): `README.md` (overview),
  `docs/USAGE.md` (scenario cookbook), `docs/MIGRATION.md` (bash → Go mapping).

## Troubleshooting fast-path

| Symptom | Do |
|---|---|
| `config problem(s)` on any command | fix what it lists; the validator also enforces server rules (service names: no hyphens). From 0.5.28 `validate` also WARNS on `_` in the service name (a new setup with one fails at step 05) |
| `the saved admin credentials … no longer sign in` | the message names the file + admin and the three causes (data reset → move that one file aside; wrong env / creds dir → `info`; password changed → update the file); `doctor --strict` checks the sign-in on demand (plain `doctor` only reads the file) |
| `permission schema name … is taken` | another org owns that name: choose a different `registration.service` (nothing was created on a first run) |
| `… registered with no owner recorded` | ask the auth team to record your service org as the schema's owner |
| user reports 403 on a new permission | the day-2 flow above (`run 04` + `backfill` for workspaces) |
| `a stale lock …` / `another authsetup run (pid N) is working …` | stale → remove the printed file; alive → wait for it |
| step 06 fails on missing perms | registration→team auto-join broken server-side; check login-config `default_team` via `status` |
| backfill 403 on workspace teams | your admin lacks authority over that child org in this env — stop and contact the platform team (`platform-team@ab0t.com`) |

## What your customers notice

A login page in your branding at `/login/<service>-users`, the default permissions from the moment they
sign up, and nothing else: they never see ab0t, `authsetup` or each other's data. A change to defaults
reaches them within about five minutes or on a fresh login; existing workspaces need `backfill`.

## Check it worked

```bash
authsetup --env dev doctor                          # read-only checklist; --strict also proves the admin sign-in
authsetup --env dev --config-dir ./config status    # 0 converged · 3 drift
authsetup --env dev --config-dir ./config run 06    # a throwaway user signs up, holds the defaults, is removed
```
Still stuck: send `authsetup --env <env> doctor --json`, `status --json`, the failing command's full
output and the latest `journal/*.jsonl` from the creds dir (secrets are redacted) to
`platform-team@ab0t.com`. Never send a credentials file.
