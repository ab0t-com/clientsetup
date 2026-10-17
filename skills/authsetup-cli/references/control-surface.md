# authsetup — full control surface

Exact commands, flags, files, and states for `authsetup` 0.5.24. When in doubt, the binary is the truth:
`authsetup --help` and `authsetup <command> --help`.

## Commands

| Command | Mutates | What it does |
|---|---|---|
| `init --publish` | local files only | A few questions (or flags) → a starter `config/` written and validated. Never overwrites. |
| `up` | yes | Plan in plain words → yes → apply (steps 01–08). Asks for the env once (never guesses prod); `--yes` for CI; `--dry-run` for the plan only. |
| `validate` | no | Check config; non-zero exit on problems. Gates all other commands. Local-only. |
| `run` | yes | Reconcile steps 01–08 in order (the expert path). |
| `run NN [NN…]` | yes | Reconcile only the named steps, in given order. |
| `status` | no | Connections + step 05 verification against the live server; exit 3 on drift. |
| `doctor` | no | You-are-here checklist (binary, auth, config, creds, admin credentials, service key, connections). Never signs in by default (a stale-password sign-in counts toward lockout); `doctor --strict` signs in once to verify the admin. |
| `backfill` | yes | Reconcile existing per-user workspace teams to `default_grant ∪ --extra-perm`. |
| `destroy` | yes | Remove the service's orgs (children first); `--dry-run` lists them; `--yes` in automation. |
| `info` | no | Local view: identities, version, dirs (+ creds provenance + git-safety), service, pattern, default role, the step → object → config-file map. |
| `settings` | `--env-file` only | Backend + frontend values for an env (key masked); `--env-file .env` writes them into a 0600 managed block. |
| `snippet login` | no | A ready sign-in block with your real client id (token standard). |
| `login-url` | no | Your users' hosted sign-in page; `--check` verifies it answers. |
| `providers` / `connect <prov>` / `disconnect <prov>` | `connect`/`disconnect` yes | Mesh directory; self-register as a consumer and mint a scoped key; revoke + archive. |
| `grant-platform` / `revoke-platform` / `platform-holders` | grant/revoke yes | Hand out / take back one of your `scope: "platform"` permissions with `--reason`; list holders. |
| `obo-actor` / `obo-enable` / `obo-disable` | yes | On-behalf-of: actor identity, read-only delegation grant, revoke. |
| `connection create\|list\|revoke` | create/revoke yes | App-to-app connections (`--consent admin\|user` required). |
| `whois <id>` / `accounts` / `env` / `use-env` | `use-env` writes one local label | Reverse lookup; identities on this machine; environments; sticky default env. |
| `update` / `migrate` | `update` swaps the binary; `migrate` imports bash-kit credentials | Self-update (sha256-verified); one-time import from the old bash kit. |
| `version` | no | Print version. |

Full list: `authsetup --help`; one command: `authsetup <command> --help`.

## Global flags & env

| Flag | Env | Default | Notes |
|---|---|---|---|
| `--env` | `AUTHSETUP_ENV` | (prod when nothing is chosen; `up` asks instead) | `prod`\|`dev`\|`local`\|custom; picks the URL AND the per-env creds file `<name>.<env>.json` |
| `--base-url` | `AUTH_SERVICE_URL` | the resolved env's URL | must agree with `--env` when both are given |
| `--config-dir` | — | `./config` | needs `permissions.json`; `oauth-client.json`/`hosted-login.json` optional |
| `--creds-dir` | `AUTHSETUP_CREDS_DIR` | `~/.authmesh/<service-id>` | flag > env > default |
| `--dry-run` | — | off | reads everything, writes nothing; prints `would:` plan + planned count |
| `--write-gitignore` | — | off | auto-append ignore entry when creds dir is unignored in a repo |
| `--unsafe-creds-in-repo` | — | off | bypass the git-safety gate (discouraged) |
| `--skip-validate` | — | off | run despite config problems (discouraged) |
| `--only-org ID` | — | — | backfill: single workspace org |
| `--extra-perm P` | — | — | backfill: repeatable, added to the canonical set |

Exit codes: `0` converged/valid · `1` failed (incl. an unknown command or step; the message says what and what
to do) · `2` unknown flag · `3` drift found by `status` · `4` cannot repair (needs a human; the object is named).
NEXT lines repeat the `--env` (or `--base-url`) you used — copy them as printed.

## Steps (what each owns)

| Step | Owns (reconciles) | Credential file written |
|---|---|---|
| 01 | checks the schema name is not owned by another org (public registry, before anything is created) · admin account (verify-or-bootstrap; `ADMIN_EMAIL` env overrides generated identity), service org (slug = `service.id`), permission-schema catalog entry (registered by the service org = its owner), service API key (`{service}-internal`, all perms, created once) | `{service}.<env>.json` |
| 02 | OAuth client on service org: RFC 7591 create, RFC 7592 redirect-URI reconcile (management token persisted + re-persisted on rotation) | `oauth-client.<env>.json` |
| 03 | hosted-login document on service org (`hosted-login.json`; fields you set overwrite, fields you omit are kept) | — |
| 04 | end-users org (`{service}-users`, child of service org) · default team **permissions synced to `default_grant` union every run** · login-config (`default_role` = configured role, `default_team`, `default_landing` from `hosted-login.json` (`"parent"`\|`"workspace"`, default `parent`; `"workspace"` requires `org_structure.pattern="workspace-per-user"`), `org_structure` with `{service_id}` substitution + `default_team_permissions` injection) · end-users OAuth client · LAST: checks the permission schema as the SERVICE org (never registers it as the end-users org) | `end-users-org.<env>.json`, `end-users-oauth-client.<env>.json` |
| 07 | for each `<config-dir>/clients.d/*.json`: customer sub-org under the provider, service account, org membership, API key (reused only while permissions match config; fresh key on drift) | `<provider>-consumer.<env>.json` |
| 08 | checks the permission schema as the SERVICE org first · `{service}-api-consumers` org · tier teams (permissions reconciled EXACTLY to config every run — extras removed) · consumer login-config (auto-join default tier, role `service_account`; self-serve sign-up OFF unless `registration.signup_enabled: true`) · mesh directory listing (`public_mesh`, default listed) | `api-consumers.<env>.json` |
| 05 | nothing — verification: health, orgs, team perms ⊇ default_grant, login page | — |
| 06 | nothing left behind — registers a throwaway user via the org-scoped flow (`/organizations/{slug}/auth/register`), asserts default_grant ⊆ effective perms (`/permissions/user/{id}?org_id=`) and the token audience, then removes the test user (pass or fail) | — |
| 09 (`backfill`) | every descendant org of the end-users org holding a team named `org_structure.config.default_team_name` (default `"Default"`): permissions ∪= canonical set | — |

## State machine

| State | Detected by | Transition |
|---|---|---|
| Invalid config | `validate` ≠ 0 | edit config |
| Unprovisioned | `run --dry-run` plans creates | `run` |
| Converged | `run` prints "no changes were needed" (re-sent settings are counted, not shown as changes) / `up` "already matches your config" / `status` ok | — |
| Drifted (server ≠ config) | `status` exit 3; `run --dry-run` plans syncs | `run` / `up` |
| Cannot repair | exit 4 + "needs you" in the summary; the object, the diff and the options are printed | a human acts (restore the creds file, rename, or ask the auth team) |
| Schema name taken | step 01/04/08 fails: `permission schema name "<svc>" is taken` | choose a different `registration.service` (or `--creds-dir` the setup that owns it) |
| Schema has no owner recorded | `… registered with no owner recorded` | ask the auth team to record your service org as its owner — re-running does not help |
| Legacy-frozen workspaces | user 403 on new perm under `workspace-per-user` | `backfill` |
| Locked | `.setup-go.lock` error saying whether that run is alive | wait (alive) or remove the file (stale) |

Removal of a permission from config does NOT remove it from the end-users default
team (step 04 syncs additively, by design); step 08's consumer tier teams ARE
reconciled exactly. To revoke elsewhere: edit the team's permission array directly
(`PUT /teams/{id}`) or revoke per-user grants — deliberate operator actions.

## config/permissions.json fields the tool consumes

```jsonc
{
  "service": { "id": "myservice",          // org slug + audience; lowercase letters and digits only (no hyphens, no _ — auth drops "_" from org names, so a new setup breaks at step 05); fixed once created
               "name": "...", "description": "...", "maintainer": "a@b.com" },
  "registration": { "service": "myservice", // registry name — the same word as service.id; letters and digits (the registry also takes _, but the org names cannot)
                    "actions": [...], "resources": [...] },
  "permissions": [ { "id": "myservice.read.items", "default_grant": true, ... } ],
  "roles": [ { "id": "myservice-user", "permissions": [...], "default": true } ],
  "end_users": {
    "default_role": "myservice-user",      // overrides roles[].default
    "default_team_name": "Default Users",
    "org_structure": { "pattern": "flat" | "workspace-per-user",
                       "config": { "slug_template": "{service_id}-{email_prefix}-{short_id}",
                                   "default_team_name": "Default",
                                   "default_team_permissions": [ ... ] } }
  }
}
```

## Credential files (in the creds dir; 0600; never commit)

| File | Shape (keys the tool owns) |
|---|---|
| `{service}.<env>.json` | `service`, `organization{id,slug}`, `admin{email,password,user_id}`, `api_key{id,key}` |
| `oauth-client.<env>.json` | RFC 7591 response incl. `registration_access_token`, `registration_client_uri` |
| `end-users-org.<env>.json` | `org_id, org_slug, parent_org_id, default_role, default_team_id/name, oauth_client_id, hosted_login_url, default_permissions[], permission_model, org_structure` |
| `end-users-oauth-client.<env>.json` | as oauth-client, for the end-users org |
| `<provider>-consumer.<env>.json` | a consumer key from `connect` or `run 07`: provider, tier, service account, `api_key{id,key}` |
| `api-consumers.<env>.json` | your step-08 consumers org: register URL, tier team ids |
| `.archive/` | credential files `disconnect` moved aside (never deleted) |
| `.setup-go.lock` | pid of a live run (auto-removed) |
| `journal/run-<ts>.jsonl` | **compliance journal** — one line per HTTP exchange: `{time, step, method, path, status, attempts, request, response, error}` with full request/response JSON, secrets `[REDACTED]` (password, tokens, client_secret, api_key…). Written for every server-touching command incl. dry-runs. Keep it: it is your audit trail. |

Legacy names (`<name>.json` for prod, `<name>-dev.json` for dev) are still read when the per-env file is absent.

**Where everything lives (one answer):** config (desired state) = your repo's `config/`; secrets + server-state snapshots + journals (actual-state artifacts) = the creds dir (`~/.authmesh/<service-id>/` by default, never in a repo); the only other writes are the `.env` you ask `settings --env-file` for and the one-line `~/.authmesh/active-env` from `use-env`. Never delete the creds dir; it holds every environment.

Saves are merge-preserving: unknown keys (e.g. written by the bash kit or a
newer version) survive round-trips.

## Installing and verifying the binary

Install or update with `curl -fsSL https://raw.githubusercontent.com/ab0t-com/clientsetup/main/install.sh | sh`
(it checks the published sha256 before writing anything and keeps the previous binary as
`authsetup.previous`), or `authsetup update`. Release binaries and `checksums.txt` are in the
`release/` folder of `https://github.com/ab0t-com/clientsetup`. Clients never build from source.
