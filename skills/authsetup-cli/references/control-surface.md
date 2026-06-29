# authsetup — full control surface

Exact commands, flags, files, and states. Source of truth: `setup-go/` source.

## Commands

| Command | Mutates | What it does |
|---|---|---|
| `validate` | no | Check config; non-zero exit on problems. Gates all other commands. |
| `run` | yes | Reconcile steps 01–08 in order. |
| `run NN [NN…]` | yes | Reconcile only the named steps, in given order. |
| `status` | no | Step 05 verification against the live server + drift report. |
| `backfill` | yes | Reconcile existing per-user workspace teams to `default_grant ∪ --extra-perm`. |
| `info` | no | Local view: version, dirs (+ creds provenance + git-safety), service, pattern, default role, state files. |
| `version` | no | Print version. |

## Global flags & env

| Flag | Env | Default | Notes |
|---|---|---|---|
| `--base-url` | `AUTH_SERVICE_URL` | `https://auth.service.ab0t.com` | `localhost`/`*.dev.ab0t.com` ⇒ `-dev` credential suffix |
| `--config-dir` | — | `./config` | needs `permissions.json`; `oauth-client.json`/`hosted-login.json` optional |
| `--creds-dir` | `AUTHSETUP_CREDS_DIR` | `~/.authmesh/<service-id>` | flag > env > default |
| `--dry-run` | — | off | reads everything, writes nothing; prints `would:` plan + planned count |
| `--write-gitignore` | — | off | auto-append ignore entry when creds dir is unignored in a repo |
| `--unsafe-creds-in-repo` | — | off | bypass the git-safety gate (discouraged) |
| `--skip-validate` | — | off | run despite config problems (discouraged) |
| `--only-org ID` | — | — | backfill: single workspace org |
| `--extra-perm P` | — | — | backfill: repeatable, added to the canonical set |

Exit codes: `0` converged/valid · `1` anything else (message says what).

## Steps (what each owns)

| Step | Owns (reconciles) | Credential file written |
|---|---|---|
| 01 | admin account (verify-or-bootstrap; `ADMIN_EMAIL` env overrides generated identity), service org (slug = `service.id`), permission-schema catalog entry, service API key (`{service}-internal`, all perms, created once) | `{service}.json` |
| 02 | OAuth client on service org: RFC 7591 create, RFC 7592 redirect-URI reconcile (management token persisted + re-persisted on rotation) | `oauth-client.json` |
| 03 | hosted-login document on service org (PUT-replace of `hosted-login.json`) | — |
| 04 | end-users org (`{service}-users`, child of service org) · default team **permissions synced to `default_grant` union every run** · org-scoped schema · login-config (`default_role` = configured role, `default_team`, `org_structure` with `{service_id}` substitution + `default_team_permissions` injection) · end-users OAuth client | `end-users-org.json`, `end-users-oauth-client.json` |
| 07 | for each `<config-dir>/clients.d/*.json`: customer sub-org under the provider, service account, org membership, API key (reused only while permissions match config; fresh key on drift) | `<provider>-consumer.json` |
| 08 | `{service}-api-consumers` org · tier teams (permissions reconciled every run) · org-scoped schema · signup login-config (auto-join default tier, role `service_account`) | `api-consumers.json` |
| 05 | nothing — verification: health, orgs, team perms ⊇ default_grant, login page | — |
| 06 | nothing persistent — registers a throwaway user via the org-scoped flow (`/organizations/{slug}/auth/register`) and asserts default_grant ⊆ effective perms (`/permissions/user/{id}?org_id=`) | — |
| 09 (`backfill`) | every descendant org of the end-users org holding a team named `org_structure.config.default_team_name` (default `"Default"`): permissions ∪= canonical set | — |

## State machine

| State | Detected by | Transition |
|---|---|---|
| Invalid config | `validate` ≠ 0 | edit config |
| Unprovisioned | `run --dry-run` plans creates | `run` |
| Converged | `run` prints "no changes were needed" / `status` ok | — |
| Drifted (server ≠ config) | `status` failures; `run --dry-run` plans syncs | `run` (additive; never removes perms) |
| Legacy-frozen workspaces | user 403 on new perm under `workspace-per-user` | `backfill` |
| Locked | `.setup-go.lock` error | remove stale lock |

Removal of a permission from config does NOT remove it server-side (additive
union by design). To revoke: edit the team's permission array directly
(`PUT /teams/{id}`) or revoke per-user grants — deliberate operator actions.

## config/permissions.json fields the tool consumes

```jsonc
{
  "service": { "id": "myservice",          // org slug; MUST match ^[a-z][a-z0-9_]*$ (server rule)
               "name": "...", "description": "...", "maintainer": "a@b.com" },
  "registration": { "service": "myservice", "actions": [...], "resources": [...] },
  "permissions": [ { "id": "myservice.read.items", "default_grant": true, ... } ],
  "roles": [ { "id": "myservice-user", "permissions": [...], "default": true } ],
  "end_users": {
    "default_role": "myservice-user",      // overrides roles[].default
    "default_team_name": "Default Users",
    "org_structure": { "pattern": "flat" | "workspace-per-user",
                       "config": { "slug_template": "{email_prefix}-{short_id}",
                                   "default_team_name": "Default",
                                   "default_team_permissions": [ ... ] } }
  }
}
```

## Credential files (in the creds dir; 0600; never commit)

| File | Shape (keys the tool owns) |
|---|---|
| `{service}[-dev].json` | `service`, `organization{id,slug}`, `admin{email,password,user_id}` |
| `oauth-client[-dev].json` | RFC 7591 response incl. `registration_access_token`, `registration_client_uri` |
| `end-users-org[-dev].json` | `org_id, org_slug, parent_org_id, default_role, default_team_id/name, oauth_client_id, hosted_login_url, default_permissions[], permission_model, org_structure` |
| `end-users-oauth-client[-dev].json` | as oauth-client, for the end-users org |
| `.setup-go.lock` | pid of a live run (auto-removed) |
| `journal/run-<ts>.jsonl` | **compliance journal** — one line per HTTP exchange: `{time, step, method, path, status, attempts, request, response, error}` with full request/response JSON, secrets `[REDACTED]` (password, tokens, client_secret, api_key…). Written for every server-touching command incl. dry-runs. Successor to the bash kit's `_raw.*` convention — every call is kept, not a subset. |

**Where everything lives (one answer):** config (desired state) = your repo's `config/`; secrets + server-state snapshots + journals (actual-state artifacts) = the creds dir (`~/.authmesh/<service-id>/` by default, never in a repo); nothing else is written anywhere.

Saves are merge-preserving: unknown keys (e.g. written by the bash kit or a
newer version) survive round-trips.

## Build & release (MAINTAINER / release-engineering only — not for clients)

> Clients do NOT build from source. Install the prebuilt binary with
> `curl -fsSL https://raw.githubusercontent.com/ab0t-com/clientsetup/main/install.sh | sh`.
> The commands below are for whoever cuts a release of `authsetup`.

```
./build.sh --local   # bin/authsetup for this machine (gated: vet/fmt/build/gitleaks)
./build.sh           # release/ matrix: linux+darwin × amd64+arm64, .sha256 each, manifest.json
```
Verify a downloaded artifact: `sha256sum -c release/authsetup-<os>-<arch>.sha256`.
