# authsetup usage cookbook

Task-oriented recipes for the full range of client situations. Written to be
followed verbatim by a human or an agent. Conventions: `$CFG` = your config
dir; dev first, prod second; `--dry-run` before every first apply.

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
| `flat` (default) | users are interchangeable consumers of a shared API (SaaS tools, dev portals, internal apps) | membership in one shared end-users org + auto-join default team |
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

Credentials are isolated per environment automatically (`-dev` file suffix
for `localhost`/`*.dev.ab0t.com`). The config is shared.

```bash
AUTH_SERVICE_URL=https://auth.dev.ab0t.com  authsetup --config-dir $CFG run   # dev
AUTH_SERVICE_URL=https://auth.service.ab0t.com authsetup --config-dir $CFG run # prod (defaults here)
authsetup --config-dir $CFG info    # shows which env-suffix + creds dir is active
```

Promote dev → prod by re-running the same config against prod; never copy
credential files between environments.

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
| shared team name | `end_users.default_team_name` | step 04 |
| workspace slug/name/team | `org_structure.config.*_template`, `default_team_name` | per-user workspaces |
| workspace perms ≠ default_grant | `org_structure.config.default_team_permissions` | workspace template |
| frontend client name/redirects | `oauth-client.json` | both OAuth clients |
| login page content/branding/security | `hosted-login.json` (PUT-replace: the file is the whole truth) | hosted login |
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
