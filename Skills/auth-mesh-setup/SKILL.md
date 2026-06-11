---
name: auth-mesh-setup
description: Onboard any service to the ab0t Auth Mesh using the setup CLI and numbered scripts (01-08). Use when registering a new service with auth, designing a permissions.json schema, configuring OAuth clients, setting up hosted login pages, creating end-users orgs with team-based permission inheritance, choosing an org_structure pattern (flat vs workspace-per-user), running or debugging setup scripts, understanding the Zanzibar permission model, verifying setup health, troubleshooting registration failures, setting up consumer/provider mesh registration, or adapting the setup system for a new service. Covers the full onboarding lifecycle from config file creation through permission design, org creation, OAuth registration, hosted login branding, default team setup, org structure selection, verification, consumer registration, and provider setup.
---

# Auth Mesh Setup

Onboard any service to Auth Mesh using the setup CLI. The system is config-driven, idempotent, and environment-aware.

## Step-by-Step: Onboarding a New Service

### 1. Clone the setup CLI into your project

```bash
git clone https://github.com/ab0t-com/client-service-setup-cli.git setup
cd setup
```

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
    "id": "your-service",           // lowercase, hyphens ok. Used in org slugs, API keys, permission IDs
    "name": "Your Service",         // human-readable
    "description": "What your service does",
    "audience": "your-service",     // JWT audience claim — usually same as service.id
    "maintainer": "team@yourcompany.com"
  }
}
```

**Registration namespace** — the building blocks for permission IDs:
```json
{
  "registration": {
    "service": "your-service",                              // permission prefix
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
      "id": "your-service.read.items",     // format: {service}.{action}.{resource}
      "name": "Read Items",
      "description": "View items",
      "default_grant": true                // true = every user gets this automatically
    },
    {
      "id": "your-service.admin",
      "name": "Admin",
      "default_grant": false,              // false = must be granted explicitly
      "implies": ["your-service.read.items", "your-service.write.items"]
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
      "id": "your-service-user",
      "name": "User",
      "permissions": ["your-service.read.items", "your-service.write.items"],
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

### 5. Run the setup

```bash
./setup run
```

This runs steps 01-06:

| Step | What happens | Config input | Credential output |
|------|---|---|---|
| 01 | Creates service org, admin, permissions, API key | `permissions.json` | `{service}.json` |
| 02 | Registers OAuth client for frontend | `oauth-client.json` | `oauth-client.json` |
| 03 | Configures hosted login page + invitation-link landing redirect | `hosted-login.json` (+ `oauth-client.json` for smart defaults) | `hosted-login.json` |
| 04 | Creates end-users org + default team with auto-join | `permissions.json` | `end-users-org.json` |
| 05 | Verifies everything | all credentials | -- |
| 06 | E2E test: registers user, checks permissions | `end-users-org.json` | -- |

All idempotent. Safe to re-run.

### 6. Wire credentials into your app

After setup, `credentials/` has all the output. These are gitignored — never commit them.

**Frontend:** use `org_slug` from `end-users-org.json` + `client_id` from `oauth-client.json`
**Backend:** use `api_key.key` + `service_audience` from `{service}.json`

### 7. (Optional) Consume other mesh services

If your service calls other services' APIs:

```bash
cp scripts/service-client-setup/clients.d/example.json.example \
   scripts/service-client-setup/clients.d/billing.json
# Edit clients.d/billing.json
./setup run 07
```

### 8. (Optional) Let other services consume yours

If other mesh services need to call YOUR APIs:

```bash
# Auto-generates config from permissions.json if config/api-consumers.json doesn't exist
./setup run 08
```

After this, other services self-register with two API calls.

## Architecture

```
Service Org (your-service)              <- step 01
+-- admin account + API key
+-- permission schema registered
|
+-- End-Users Org (your-service-users)  <- step 04
|   +-- Default Team                    <- holds default_grant permissions
|   |   +-- new users auto-join
|   +-- User A (member -> team -> permissions)
|   +-- User B (member -> team -> permissions)
|   +-- OAuth client + hosted login
|
+-- API Consumers Org (step 08, optional)
    +-- Read-Only team (default auto-join)
    +-- Standard team (upgrade tier)
```

### Permission Flow

```
User registers -> joins end-users org -> auto-joins Default Team -> inherits team permissions
```

No webhooks, cron, callbacks, or per-user grants. Zanzibar resolves it at check time.

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
End-Users Org (your-service-users)
  ├── Default Users team        (existing)
  ├── alice's workspace         (new — settings.type = "user_workspace", owner = alice)
  │     └── Default team        (with default_grant perms)
  └── bob's workspace
        └── Default team
```

Each user is owner of their own workspace. Cross-user isolation enforced by
existing Zanzibar permission boundary — Bob cannot see or touch Alice's
workspace.

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

```bash
./setup              # Interactive menu
./setup run          # Run all pending steps
./setup run 04       # Run specific step
./setup status       # Show progress
./setup verify       # Run checks (step 05)
./setup dry-run      # Preview without changes
```

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
