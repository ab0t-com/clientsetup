---
name: auth-mesh-setup
description: Onboard any service to the ab0t Auth Mesh using the authsetup binary. Use when registering a new service with auth, designing a permissions.json schema, configuring OAuth clients, setting up hosted login pages, creating end-users orgs with team-based permission inheritance, choosing an org_structure pattern (flat vs workspace-per-user), running or debugging the authsetup steps, understanding the Zanzibar permission model, verifying setup health, troubleshooting registration failures, setting up consumer/provider mesh registration, or adapting the setup system for a new service. Covers the full onboarding lifecycle from config file creation through permission design, org creation, OAuth registration, hosted login branding, default team setup, org structure selection, verification, consumer registration, and provider setup.
---

# Auth Mesh Setup

Onboard any service to Auth Mesh using the `authsetup` binary. The system is config-driven, idempotent, and environment-aware. Every command reconciles `config/*.json` (desired state) against auth — there is no `update` command; edit config and `run` again.

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

## Step-by-Step: Onboarding a New Service

### 1. Install the `authsetup` binary

```bash
curl -fsSL https://raw.githubusercontent.com/ab0t-com/clientsetup/main/install.sh | sh
```

This installs a single static binary, `authsetup`. (A prebuilt binary from the repo's `release/` directory works too.) Create a `config/` directory next to it to hold your JSON config; example configs live in the repo's `config/`.

### 2. Create `config/permissions.json`

This is the most important file. It defines your service.

```bash
cp config/permissions.json.example config/permissions.json
```

Edit it — you MUST change these sections:

**Service identity:**
```json
{
  "service": {
    "id": "myservice",           // lowercase, NO hyphens (underscores ok), server rule ^[a-z][a-z0-9_]*$. Used in org slugs, API keys, permission IDs
    "name": "Your Service",         // human-readable
    "description": "What your service does",
    "audience": "myservice",     // JWT audience claim — usually same as service.id
    "maintainer": "team@yourcompany.com"
  }
}
```

**Registration namespace** — the building blocks for permission IDs:
```json
{
  "registration": {
    "service": "myservice",                              // permission prefix
    "actions": ["read", "write", "create", "delete", "admin"],  // verbs
    "resources": ["items", "reports", "settings"]               // nouns
  }
}
```

**Permissions** — every permission your service uses:
```json
{
  "permissions": [
    {
      "id": "myservice.read.items",     // format: {service}.{action}.{resource}
      "name": "Read Items",
      "description": "View items",
      "default_grant": true                // true = every user gets this automatically
    },
    {
      "id": "myservice.admin",
      "name": "Admin",
      "default_grant": false,              // false = must be granted explicitly
      "implies": ["myservice.read.items", "myservice.write.items"]
    }
  ]
}
```

Rules for `default_grant`:
- `true` — core features every user needs (read own data, create resources)
- `false` — admin, delete, cross-tenant, anything dangerous or costly

**Roles:**
```json
{
  "roles": [
    {
      "id": "myservice-user",
      "name": "User",
      "permissions": ["myservice.read.items", "myservice.write.items"],
      "default": true    // new users get this role
    }
  ]
}
```

See [references/permissions-design.md](references/permissions-design.md) for the complete field reference.

### 3. Create `config/oauth-client.json`

```bash
cp config/oauth-client.json.example config/oauth-client.json
```

Change:
- `client_name` — your service's display name
- `redirect_uris` — your frontend callback URLs (keep localhost for dev)

### 4. Create `config/hosted-login.json`

```bash
cp config/hosted-login.json.example config/hosted-login.json
```

Change:
- `branding.page_title` — your service name
- `content.welcome_message` — what users see on the login page
- `security.post_logout_redirect_uri` — your service's URL
- `registration.default_landing` (optional) — `"workspace"` to land users
  directly in their own workspace org on login (requires
  `workspace-per-user`; default `"parent"`). See [Org Structures](#org-structures-end_usersorg_structure).

### 5. Run the setup

Validate config, preview, then apply:

```bash
authsetup --config-dir ./config validate
AUTH_SERVICE_URL=https://auth.dev.ab0t.com authsetup --config-dir ./config --dry-run run
authsetup --config-dir ./config run
```

Global flags (`--config-dir`, `--dry-run`) go BEFORE the subcommand. `run` executes steps 01-06:

| Step | What happens | Config input | Credential output |
|------|---|---|---|
| 01 | Creates service org, admin, permissions, API key | `permissions.json` | `{service}.json` |
| 02 | Registers OAuth client for frontend | `oauth-client.json` | `oauth-client.json` |
| 03 | Configures hosted login page + invitation-link landing redirect | `hosted-login.json` (+ `oauth-client.json` for smart defaults) | `hosted-login.json` |
| 04 | Creates end-users org (your **human end users**) + default team with auto-join | `permissions.json` | `end-users-org.json` |
| 05 | Verifies everything | all credentials | -- |
| 06 | E2E test: registers user, checks permissions | `end-users-org.json` | -- |

All idempotent. Safe to re-run.

### 6. Wire credentials into your app

After setup, credentials live in `~/.authmesh/<service>/` (mode 0600, outside any repo, with a redacted journal). Never commit them.

**Frontend:** use `org_slug` from `end-users-org.json` + `client_id` from `oauth-client.json`
**Backend:** use `api_key.key` + `service_audience` from `{service}.json`

### 7. (Optional) Consume other mesh services

If your service calls other services' APIs:

```bash
# Drop a clients.d/<provider>.json into your config dir, then run step 07
# e.g. config/clients.d/billing.json — provider details + permissions you need
authsetup --config-dir ./config run 07
```

### 8. (Optional) Let other services consume yours

If other mesh services need to call YOUR APIs:

```bash
# Auto-generates config from permissions.json if config/api-consumers.json doesn't exist
authsetup --config-dir ./config run 08
```

After this, other services self-register with two API calls.

## Architecture

```
Service Org (myservice)              <- step 01
+-- admin account + API key
+-- permission schema registered
|
+-- End-Users Org (myservice-users)  <- step 04   [YOUR END USERS: humans who sign in]
|   +-- Default Team                    <- holds default_grant permissions
|   |   +-- new users auto-join
|   +-- User A (member -> team -> permissions)
|   +-- User B (member -> team -> permissions)
|   +-- OAuth client + hosted login
|
+-- API Consumers Org (myservice-api-consumers, step 08, optional)   [MESH CONSUMERS: other services calling your API]
    +-- Read-Only team (default auto-join)
    +-- Standard team (upgrade tier)
```

### Permission Flow

```
A HUMAN END USER registers -> joins end-users org -> auto-joins Default Team -> inherits team permissions
```

No webhooks, cron, callbacks, or per-user grants. Zanzibar resolves it at check time.

**Adding users?** Humans self-register at the hosted login page (`/login/{service}-users`);
other services self-register as mesh consumers via `authsetup connect` or step 08's
`register_url`. There is deliberately no manual add-user command — the mesh is self-serve
and `authsetup` reconciles from config.

## Org Structures (`end_users.org_structure`)

By default new users join a single shared end-users org. For services where each
user needs a private space (their own API keys, their own teammates, their own
billable scope), set `org_structure.pattern = "workspace-per-user"` in
`permissions.json`. The auth service has a built-in event handler that
materializes the chosen structure on every `auth.user.registered` event.

### When to recommend each pattern

Ask the client what their product looks like:

| If client says... | Recommend |
|---|---|
| "shared API anyone can call" | `flat` (default) |
| "internal dashboard for our staff" | `flat` |
| "developer tool / playground" | `flat` |
| "users have their own projects/spaces" | `workspace-per-user` |
| "users invite teammates into their account" | `workspace-per-user` |
| "we sell to companies, each gets a tenant" | `workspace-per-user` for now (true B2B "enterprise-on-billing-tier" pattern coming later) |
| "our users are bots/agents/services" | `flat` (no human ownership concept) |

### How to enable

Two-line addition to `config/permissions.json`:

```json
{
  "end_users": {
    "org_structure": {
      "pattern": "workspace-per-user"
    }
  }
}
```

Optional `config` sub-block for fine-tuning (slug template, team name). Defaults
work fine — only override if the client has specific requirements.

After setup, every new signup gets:
- The end-users org membership + default team (existing behavior preserved)
- A NEW nested workspace org under end-users-org
- Owner role on their workspace
- Membership in the workspace's own default team (carrying `default_grant` perms)

### What the client gets

```
End-Users Org (myservice-users)
  ├── Default Users team        (existing)
  ├── alice's workspace         (new — settings.type = "user_workspace", owner = alice)
  │     └── Default team        (with default_grant perms)
  └── bob's workspace
        └── Default team
```

Each user is owner of their own workspace. Cross-user isolation enforced by
existing Zanzibar permission boundary — Bob cannot see or touch Alice's
workspace.

### Land users in their workspace (`registration.default_landing`)

By default a logged-in user lands on the shared end-users (parent) org and has
to switch into their workspace manually. Set `registration.default_landing =
"workspace"` in `config/hosted-login.json` so that **login** scopes the token
straight to the user's own workspace org — no org-switch step:

```json
{
  "registration": {
    "default_landing": "workspace"
  }
}
```

- Enum: `"workspace" | "parent"` (case-sensitive, default `"parent"` =
  today's behavior). Invalid values are rejected.
- **Prerequisite:** `org_structure.pattern = "workspace-per-user"` — there must
  be a workspace to land in. It does nothing (and has nothing to scope to)
  under `flat`, so set the two together.
- Applies to **login** only. Registration always lands on the parent (the
  workspace is materialized just after signup), so the first login right after
  signup may still land on the parent until the workspace exists — it resolves
  on the next login and never errors (async-safe parent fallback).

Step 04 writes it into the end-users org's login-config. An operator can also
change it live later without re-running setup — `PUT
/organizations/{end_users_org_id}/login-config` is a partial **deep-merge**, so
send just the one field:

```bash
curl -X PUT "$AUTH_URL/organizations/$EU_ORG_ID/login-config" \
  -H "Authorization: Bearer $ADMIN_EU_TOKEN" -H 'Content-Type: application/json' \
  -d '{ "registration": { "default_landing": "workspace" } }'
```

### Backward compat (very important)

`org_structure` is optional. Omitting it = `pattern: "flat"` = existing
behavior. Pure auth-service deploys without setup-kit changes are
zero-impact for every existing client.

If a client switches from `flat` → `workspace-per-user` later, only NEW
signups get workspaces. Pre-existing users do NOT get backfilled (login is
not a creation trigger). This is by design — safe rollout.

### What's coming (NOT shipped yet)

The pattern enum is designed to grow. Future patterns under exploration:

- `enterprise-on-billing-tier` — auto-create enterprise org on billing upgrade
- `workspace-plus-enterprise` — combination of personal workspace + enterprise upgrade path

Schema enum will be extended additively. Existing client configs never break.
Clients asking about these patterns today: tell them "coming soon, use
`workspace-per-user` for now or let us know your specific needs."

### Implementation reference (for the curious)

Auth service module: `appv2/event_handlers/workspace_provisioning.py`. Mirrors
the existing `zanzibar_sync.py` shape — registered at app startup, subscribes
to `auth.user.registered`, runs in-process, best-effort error handling.
Workspaces are NOT a new primitive — they're nested orgs with
`settings.type = "user_workspace"` and `settings.owner_user_id = <user_id>`.
The handler reads the org's `login_config.registration.org_structure` to decide
what to materialize.

## CLI Usage

Global flags (`--config-dir`, `--dry-run`) go BEFORE the subcommand.

```bash
authsetup --config-dir ./config validate           # Validate config without calling auth
authsetup --config-dir ./config run                # Run all pending steps
authsetup --config-dir ./config run 04             # Run a specific step
authsetup --config-dir ./config status             # Read-only health/progress check (replaces "verify")
authsetup --config-dir ./config --dry-run run      # Preview without changes
authsetup --config-dir ./config backfill           # Reconcile/backfill existing state
```

Every command reconciles desired state and is re-runnable. There is no `update` command — edit `config/*.json` and `run` again.

Environment: `AUTH_SERVICE_URL=https://auth.service.ab0t.com` (default). Set to `http://localhost:8001` for local dev.

## Config Files Summary

| File | What to put in it | Used by |
|---|---|---|
| `config/permissions.json` | Service ID, name, audience, permissions, roles | Steps 01, 04, 08 |
| `config/oauth-client.json` | Client name, redirect URIs | Step 02 |
| `config/hosted-login.json` | Branding, signup settings | Step 03 |
| `config/api-consumers.json` | Consumer tier definitions (auto-generates if missing) | Step 08 |
| `clients.d/{provider}.json` | Provider details + permissions you need | Step 07 |

## References

- **[Permission design](references/permissions-design.md)** — complete `permissions.json` schema, field reference, `default_grant` rules, `implies` chains
- **[OAuth and hosted login](references/oauth-hosted-login.md)** — OAuth client config, hosted login branding, redirect URIs
- **[Script internals](references/script-internals.md)** — what each numbered script does step-by-step, API endpoints called
- **[Credential schemas](references/credential-schemas.md)** — output file formats for all credential files
- **[Zanzibar model](references/zanzibar-model.md)** — how parent orgs, teams, and permission inheritance work
- **[Troubleshooting](references/troubleshooting.md)** — common errors, stale credentials, DB wipe recovery
