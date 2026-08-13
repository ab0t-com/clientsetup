# authsetup usage cookbook

Task-oriented recipes for the full range of client situations. Written to be
followed verbatim by a human or an agent. Conventions: `$CFG` = your config
dir; dev first, prod second; `--dry-run` before every first apply.

### The three orgs authsetup creates (know which is which)

Onboarding gives your service **three** orgs, for three different audiences:

| Org (slug) | Who it's FOR | Login-config here | How they get in |
|---|---|---|---|
| `{service}` | your **master workspace** (admin) | the hosted login page | you, the operator |
| `{service}-users` | your **END USERS — humans** who sign into your product | signup | self-serve at the hosted login page |
| `{service}-api-consumers` | **MESH CONSUMERS — other services** that call your API | signup | `authsetup connect` / the published `register_url` |

Two directions: you **PROVIDE** (`run`; step 08 opens your API) and you **CONSUME**
(`providers` → `connect`; step 07). The word **"consumer" always means another service,
never a human** — say "mesh consumer (other service)" or "consume an upstream provider".

## TOC
1. [First-time onboarding](#1-first-time-onboarding)
2. [Choosing an org structure](#2-choosing-an-org-structure)
3. [Day-2 changes](#3-day-2-changes)
4. [The backfill playbook](#4-the-backfill-playbook)
5. [Multi-environment (dev → prod)](#5-multi-environment)
6. [Automation: CI](#6-automation-ci)
7. [Automation: agents](#7-automation-agents)
8. [Customization points](#8-customization-points)
9. [Recovery & repair](#9-recovery--repair)
11. [Adding users](#11-adding-users)

---

## 1. First-time onboarding

```bash
cp config/permissions.json.example $CFG/permissions.json   # then EDIT it:
#  - service.id            your service slug (lowercase, NO hyphens — server rule)
#  - registration.*        the action/resource vocabulary of your API
#  - permissions[]         one entry per permission; default_grant:true = every user gets it
#  - roles[]               optional named bundles; mark ONE default:true
#  - end_users.org_structure.pattern   "flat" or "workspace-per-user" (see §2)
cp config/oauth-client.json.example $CFG/oauth-client.json # your frontend redirect URIs
cp config/hosted-login.json.example $CFG/hosted-login.json # branding + registration rules

authsetup --config-dir $CFG validate
AUTH_SERVICE_URL=https://auth.dev.ab0t.com authsetup --config-dir $CFG --dry-run run
AUTH_SERVICE_URL=https://auth.dev.ab0t.com authsetup --config-dir $CFG run
AUTH_SERVICE_URL=https://auth.dev.ab0t.com authsetup --config-dir $CFG run 06   # e2e proof
```

Wire your frontend to the printed hosted-login URL + the end-users OAuth
`client_id` (in `~/.authmesh/<service>/end-users-oauth-client-dev.json`).

> **Truth-teller (roles caveat):** the `roles[]` in `permissions.json` set the
> default role *name* only. The server does not yet resolve custom
> role→permission mappings, so a role does NOT confer its permissions today.
> Grant permission tiers via the team or `authsetup backfill --extra-perm`, not
> via `roles[]`.

## 2. Choosing an org structure

| Pattern | Choose when | What users get |
|---|---|---|
| `flat` (default) | your human users are interchangeable members of a shared API (SaaS tools, dev portals, internal apps) | membership in one shared end-users org + auto-join default team |
| `workspace-per-user` | each user is a tenant with private space — their own keys, teammates, billable usage (GitHub-namespace / Notion-personal model) | everything above **plus** a private child org they own, with its own default team |

Set it in `end_users.org_structure`:

```jsonc
"org_structure": {
  "pattern": "workspace-per-user",
  "config": {
    "slug_template": "{service_id}-{email_prefix}-{short_id}",  // {service_id} substituted at setup
    "name_template": "{email_prefix}'s workspace",
    "default_team_name": "Default",
    // optional; defaults to your default_grant set:
    "default_team_permissions": ["myservice.read.items"]
  }
}
```

**Operational consequence of `workspace-per-user`** (be honest with yourself
here): each existing workspace carries a *frozen copy* of the permission set
from its creation time. Adding a permission later requires the
[backfill playbook](#4-the-backfill-playbook) for existing users until the
platform's live-policy work removes the need. `flat` has no such step.

**Land users in their workspace on login (`registration.default_landing`).**
`workspace-per-user` creates a workspace, but by default a logged-in user still
lands on the shared parent org and switches into their workspace by hand. Set
`registration.default_landing = "workspace"` in `hosted-login.json` so **login**
scopes the token straight to the user's own workspace org:

```jsonc
// hosted-login.json → registration
"default_landing": "workspace"   // "workspace" | "parent"  (default "parent")
```

Enum-validated (case-sensitive). It **requires** `workspace-per-user` — under
`flat` there is no workspace to land in, so set the two together. Login-only and
async-safe: registration always lands on the parent (the workspace is created
just after signup), so the first login right after signup may still land on the
parent until the workspace materializes, then resolves on the next login (never
errors). Applied by `run 03`/`run 04`; to flip it live later, `PUT
/organizations/{end_users_org_id}/login-config` is a deep-merge — send just
`{"registration":{"default_landing":"workspace"}}`.

**Other archetypes** (`config/archetypes/`: b2b-multi-tenant, departmental,
corporate, reseller, dynamic) document the org shapes the mesh is designed
for; authsetup provisions `flat` and `workspace-per-user` today. If your
target shape is one of the others, talk to the platform team before
improvising — several of their advertised features (permission ceilings,
TTL orgs) are platform-roadmap items.

## 3. Day-2 changes

The universal loop: **edit config → `--dry-run run` → `run`**. Specifics:

| Change | Steps touched | Existing users affected? |
|---|---|---|
| new `default_grant` permission | `run 01` `run 04` | flat: yes, immediately (shared team synced). workspace-per-user: new+future yes; existing workspaces need §4 |
| new non-default permission (role-tier) | `run 01`; grant via team/`backfill --extra-perm` | only where you grant it |
| redirect URIs | `run 02`, `run 04` | n/a (frontend config) |
| branding / signup rules / invite redirects | `run 03`, `run 04` | next page load |
| default role or team name | `run 04` | new signups |
| remove a permission | **not automatic by design** — syncs are additive. Edit the team array server-side (`PUT /teams/{id}`) deliberately | — |

After permission changes: users see updates within ~5 minutes (permission
cache) or immediately on fresh login.

> **Truth-teller:** a newly-registered permission/service becomes visible
> within ~5 min (registry cache TTL) or on a user's fresh login — so don't be
> alarmed if a brand-new permission 403s for the first few minutes right after
> `run 01`. It is not a misconfiguration; wait out the TTL or re-login.

## 4. The backfill playbook

When: `workspace-per-user` + you added a permission + existing users 403.

```bash
authsetup backfill --dry-run                      # see candidates + exactly what would be added
authsetup backfill --only-org <one-workspace-id>  # validate on ONE user
#   → that user re-logs-in → previously-403 endpoint now works
authsetup backfill                                # full sweep (idempotent; rerun-safe)
```

- `--extra-perm myservice.write.items` (repeatable) adds role-tier perms the
  workspace owner should hold beyond `default_grant`.
- Additive only — never removes operator-added perms.
- If the single-workspace run returns 403 on the team update, your admin
  lacks authority over child workspace orgs in this environment — stop and
  contact the platform team (known platform watch-item).

## 5. Multi-environment

Pick the target environment with one flag — `--env` (or `AUTHSETUP_ENV`) — and
`authsetup` resolves the auth-service URL and keeps that env's credentials
isolated from every other. **The config is shared** across all envs; only
credentials are per-env. Every command prints the active env (`· env: <name>`)
so you always see which server you're hitting.

```bash
authsetup --config-dir $CFG --env dev   run   # → auth.dev.ab0t.com
authsetup --config-dir $CFG --env prod  run   # → auth.service.ab0t.com (the default)
authsetup --config-dir $CFG --env local run   # → http://localhost:8001
authsetup --config-dir $CFG env               # list built-ins + registry + which env resolved
authsetup --config-dir $CFG info              # lists ALL <svc>.<env>.json present for the service
```

**Built-in envs.** `prod`, `dev`, `local` ship out-of-box with the URLs above;
`prod` is the default when nothing is specified (existing scripts/CI are
unchanged). Any other name (`staging`, `eu`, …) is a **custom env** you define
in the registry (below).

**How the env resolves** — `--env` > `AUTHSETUP_ENV` > a label derived from an
explicit `--base-url`/`AUTH_SERVICE_URL` > default `prod`. An unknown `--env`
is an **error**, never a silent fall-back to prod.

**Agreement rule.** If you pass BOTH `--env X` and an explicit
`--base-url`/`AUTH_SERVICE_URL`, and the URL is *not* env `X`'s resolved URL,
the command **errors** rather than silently sending env-`X`-labelled creds to a
different server. Pass one or the other, or make them agree.

**Per-env credential files.** Credentials live in the same flat
`~/.authmesh/<service>/` dir, labelled by env in the filename:
`<name>.<env>.json` (e.g. `<service>.dev.json`,
`end-users-oauth-client.prod.json`). No subdirectories. Saves are **additive** —
they never move or rewrite another env's file. For back-compat, an env reads a
legacy unlabelled file read-only when its own file is absent: env `dev` falls
back to the old `<name>-dev.json` and env `prod` to the old `<name>.json`; any
other env starts fresh. The first save under that env writes the new
`<name>.<env>.json` and leaves the legacy file untouched.

**Custom envs (the registry).** Define extra envs (or override a built-in URL)
in `~/.authmesh/environments.json`, or check a team copy into the repo at
`<config-dir>/environments.json` (repo-local wins). **URLs only** — any
secret-looking field is ignored with a warning, so the repo-local file is safe
to commit.

```jsonc
// ~/.authmesh/environments.json  (or <config-dir>/environments.json)
{
  "environments": {
    "staging": { "auth_service_url": "https://auth.staging.ab0t.com" },
    "dev":     { "auth_service_url": "https://auth.dev.internal" }   // override a built-in
  }
}
```

Promote dev → prod by re-running the same config against prod
(`--env prod`); never copy credential files between environments.

## 6. Automation: CI

```yaml
# pipeline sketch — exit code is the contract
- run: authsetup --config-dir ./config validate
- run: AUTHSETUP_CREDS_DIR=/var/lib/authmesh/$SERVICE \
       AUTH_SERVICE_URL=$AUTH_URL \
       authsetup --config-dir ./config run
```

- Set `AUTHSETUP_CREDS_DIR` to a persistent volume **outside the checkout**
  (the git-safety gate hard-fails non-interactive runs into unignored repo
  paths — that's intentional).
- Concurrency: the lockfile serializes runs per creds dir; parallel pipelines
  against the same service will fail fast rather than interleave.
- Compliance: archive `$AUTHSETUP_CREDS_DIR/journal/*.jsonl` as build
  artifacts — they are the redacted, replayable record of every API exchange.
- Drift check as a scheduled job: `authsetup status` (read-only, non-zero on
  drift) → alert → a human (or agent) reviews `--dry-run run` and applies.

## 7. Automation: agents

Agents get a first-class control surface:

- **Load the skill** `Skills/authsetup-cli/` (Agent Skills standard — Claude
  Code, Codex, Gemini, opencode all read it). It encodes the operating model,
  recipes, and the exact flag matrix so the agent doesn't guess.
- Everything is non-interactive-safe: no command ever blocks on a prompt
  unless stdin is a TTY; the only interactive path (gitignore consent) has
  flag equivalents (`--write-gitignore`).
- The contract for autonomous use: `--dry-run` first, read the plan, apply
  only if it matches intent; treat exit 0 as converged; surface the printed
  server `detail` on failures rather than blind-retrying; never use
  `--skip-validate` or `--unsafe-creds-in-repo` without human signoff.
- Machine-readable state: `info` (local), `status` (server), plus the
  credential JSONs themselves (stable shapes documented in the skill's
  control-surface reference).
- **Truth-teller — "already exists" status codes differ:** if you script
  around the auth API directly, a duplicate ORG slug returns **409** but a
  duplicate ACCOUNT email returns **400**. Treat both as benign-idempotent
  ("already there"), not as fatal errors — handle each code explicitly.

## 8. Customization points

| Knob | Where | Effect |
|---|---|---|
| default permissions for every user | `permissions[].default_grant` | shared team + workspace template |
| default role name on signup | `roles[].default` / `end_users.default_role` | written into login-config |
| land users in their workspace on login | `hosted-login.json` `registration.default_landing` (`"workspace"`; needs `workspace-per-user`) | login token scoped to the user's own workspace org |
| shared team name | `end_users.default_team_name` | step 04 |
| workspace slug/name/team | `org_structure.config.*_template`, `default_team_name` | per-user workspaces |
| workspace perms ≠ default_grant | `org_structure.config.default_team_permissions` | workspace template |
| frontend client name/redirects | `oauth-client.json` | both OAuth clients |
| login page content/branding/security | `hosted-login.json` (deep-merged onto login-config; fields you set overwrite, omitted preserved) | hosted login |
| admin identity at bootstrap | `ADMIN_EMAIL` env on first `run 01` | service admin account |
| creds location | `--creds-dir` / `AUTHSETUP_CREDS_DIR` | see README §credentials |

## 9. Recovery & repair

| Situation | Recipe |
|---|---|
| run failed mid-way | just `run` again — completed work no-ops, the remainder applies |
| lost credentials dir | you lose admin password + OAuth management tokens. Recover the admin via the auth service's password reset (admin email is in your records); OAuth clients without their RFC 7592 token must be re-registered under a new `client_name`. Then `run` reconciles around the recovered identity |
| someone hand-edited server state | `status` shows the drift; `run` converges it (additively) |
| wrong env applied | nothing is shared between envs except your config; re-run against the right `AUTH_SERVICE_URL`; clean up the wrong env's orgs deliberately via the auth API |
| stale lockfile | error prints the path + pid; verify the pid is dead; remove the file |
| bash kit and authsetup mixed | fully supported — same files; see docs/MIGRATION.md |

## 10. Rotating credentials

The admin password and the service-internal API key both live in
`~/.authmesh/<service>/<service>.json`. Rotate them on your security policy's
cadence:

- **Service API key** (the `api_key` block): `run 01` treats a present key as
  done, so to rotate you mint a new one and revoke the old.
  1. In the creds file, clear the `api_key` object (set it to `{}`), then
     `authsetup --config-dir ./config run 01` → it provisions a **fresh** key and
     re-saves it.
  2. Roll the new key out to your consumers, then revoke the old key id via the
     auth service: `DELETE /api-keys/{old_id}`.
- **Admin password** (`admin.password`): change it server-side (the auth
  service's password-change / reset for the admin email), then update
  `admin.password` in the creds file so `authsetup` can still log in. There is no
  rotate command — the admin is a normal auth account.
- **OAuth registration token**: rotates automatically — the RFC 7592 update path
  (`run 02`/`run 04` on redirect drift) re-persists any new
  `registration_access_token` the server returns.

Never commit these files (they are 0600 and outside any repo by default). After
rotating, the redacted compliance journal records the exchange for your audit
trail.

---

## 11. Adding users

**Humans (your end users)** self-register at the hosted login page `run` step 04
stands up: `{base}/login/{service}-users` (i.e. `POST /organizations/{service}-users/auth/register`).
Signup is enabled with a default team + default role, so a new human lands with
the baseline permissions automatically. Your own backend may also create users
via the auth API/SDK during its signup flow — that is an application concern.

**Services (mesh consumers)** self-register with `authsetup connect <you>` or the
provider's published `register_url` from `run 08`.

There is **deliberately no `authsetup add-user` command.** The mesh is self-serve
by design and `authsetup` reconciles from config — a hand-added user would live
nowhere in config and drift. Point humans at the hosted login page; point services
at `connect`.
