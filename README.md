# Auth Mesh Client Setup

Set up your service with Auth Mesh in minutes. This CLI registers your service,
configures authentication, and ensures users can access your application with
zero ongoing maintenance.

## Step-by-Step Setup Guide

### Prerequisites

- **bash** 4.0+, **curl**, **jq** installed
- Network access to your Auth Mesh instance
- You know your service's name, ID, and what permissions it needs

### Step 1: Get the setup CLI

Clone or copy this repo into your service's project directory:

```bash
git clone https://github.com/ab0t-com/client-service-setup-cli.git setup
cd setup
```

### Step 2: Configure your service identity — `config/permissions.json`

This is the most important file. It tells Auth Mesh who your service is and what
permissions it uses.

```bash
cp config/permissions.json.example config/permissions.json
```

Open `config/permissions.json` and fill in:

**2a. Service identity** — change these to match YOUR service:

```json
{
  "service": {
    "id": "my-service",           // lowercase, hyphens ok. Used everywhere: org slugs, API keys, permission IDs
    "name": "My Service",         // human-readable display name
    "description": "What my service does",
    "version": "1.0.0",
    "audience": "my-service",     // JWT audience claim — usually same as service.id
    "maintainer": "team@yourcompany.com"
  }
}
```

**2b. Registration namespace** — defines the building blocks for permission IDs:

```json
{
  "registration": {
    "service": "my-service",      // permission prefix — all IDs start with this
    "actions": ["read", "write", "create", "delete", "admin"],  // verbs your service supports
    "resources": ["items", "reports", "settings"]                // nouns your service manages
  }
}
```

**2c. Permissions** — list every permission your service uses:

```json
{
  "permissions": [
    {
      "id": "my-service.read.items",        // format: {service}.{action}.{resource}
      "name": "Read Items",
      "description": "View items in the catalog",
      "risk_level": "low",
      "cost_impact": false,
      "default_grant": true                  // true = every user gets this automatically
    },
    {
      "id": "my-service.admin",
      "name": "Administrator",
      "description": "Full admin access",
      "risk_level": "critical",
      "default_grant": false,                // false = admin must grant explicitly
      "implies": [                           // admin gets all these automatically
        "my-service.read.items",
        "my-service.write.items",
        "my-service.delete.items"
      ]
    }
  ]
}
```

How to decide `default_grant`:
- `true` — core features every user needs (reading data, creating their own resources)
- `false` — dangerous or admin operations (delete all, admin, cross-tenant access)

**2d. Roles** — group permissions into named roles:

```json
{
  "roles": [
    {
      "id": "my-service-user",
      "name": "User",
      "permissions": ["my-service.read.items", "my-service.write.items"],
      "default": true                        // new users get this role
    },
    {
      "id": "my-service-admin",
      "name": "Admin",
      "permissions": ["my-service.admin"],
      "default": false
    }
  ]
}
```

See `config/permissions.json.example` for a complete working example with all fields.

### Step 3: Configure your OAuth client — `config/oauth-client.json`

This registers an OAuth 2.1 client so your frontend can authenticate users.

```bash
cp config/oauth-client.json.example config/oauth-client.json
```

Open `config/oauth-client.json` and change:

```json
{
  "client_name": "My Service Frontend",      // display name
  "redirect_uris": [
    "https://my-service.com/auth/callback",  // your production callback URL
    "http://localhost:3000/auth/callback"     // keep this for local dev
  ],
  "grant_types": ["authorization_code", "refresh_token"],
  "response_types": ["code"],
  "token_endpoint_auth_method": "none",      // "none" for SPAs and mobile apps
  "scope": "openid profile email"
}
```

The only things you MUST change:
- `client_name` — your service's name
- `redirect_uris` — your actual callback URLs

### Step 4: Configure your login page — `config/hosted-login.json`

This brands the hosted login page your users will see.

```bash
cp config/hosted-login.json.example config/hosted-login.json
```

Open `config/hosted-login.json` and change:

```json
{
  "branding": {
    "primary_color": "#111111",              // your brand color (hex)
    "page_title": "My Service - Sign In"     // browser tab title
  },
  "content": {
    "welcome_message": "Sign in to My Service",
    "signup_message": "Create your account",
    "footer_message": "My Service by Your Company"
  },
  "auth_methods": {
    "email_password": true,
    "signup_enabled": true,                  // set false to disable self-registration
    "invitation_only": false                 // set true to require invitations
  },
  "registration": {
    "default_role": "end_user",
    "require_email_verification": false,
    "collect_name": true
  },
  "security": {
    "post_logout_redirect_uri": "https://my-service.com",  // where to go after logout

    // PART3 — invitation-link landing redirect (optional but recommended).
    // The auth service hosts /accept-invite as the canonical click target
    // and 302-redirects the invitee to the URL you configure here.
    "accept_invite_url": "https://my-service.com/welcome",
    "accept_invite_error_url": "https://my-service.com/invite-error",
    // Leave [] to smart-default from oauth-client.json redirect_uris
    // (those origins are already trusted for OAuth callbacks). Or
    // populate explicitly if your invite-landing origins differ.
    "accept_invite_allowed_origins": []
  }
}
```

**About the `accept_invite_*` fields** (added by PART3, May 2026):

**Do I need this?** If your service uses `POST /organizations/{id}/invite`
to onboard users, configure these. If your users only register via your
app's signup form, you can leave them unset.

When you POST `/organizations/{id}/invite`, the email link points at
`{AUTH_SERVICE_URL}/accept-invite?code=...`. The auth service then
302-redirects the invitee to **your** app — to whichever URL you
configure here.

- `accept_invite_url` — where valid invitations land. Auth appends `?code=<...>`.
- `accept_invite_error_url` — where used / expired / unknown invitations land. Auth appends `?reason=used|expired|not_found|invalid`.
- `accept_invite_allowed_origins` — open-redirect defense. Each entry is `scheme://host[:port]` (no path). Smart-defaulted from `oauth-client.json` redirect_uris when empty.

Leave the URL fields unset to use the bundled fallback page on the auth
service. Different schemes count as different origins (`https://app` and
`http://app` need separate allowlist entries).

### Step 5: Run the setup

```bash
./setup run
```

This runs steps 01 through 06 in order:

| Step | What happens | What it creates |
|------|---|---|
| 01 | Registers your service | Service org + admin account + API key + permissions |
| 02 | Registers OAuth client | OAuth client_id for your frontend |
| 03 | Configures login page | Branded login page at auth.service.ab0t.com/login/{slug} |
| 04 | Creates end-users org | Org where users sign up + default team with auto-join permissions |
| 05 | Verifies everything | Checks all orgs, teams, login config are correct |
| 06 | End-to-end test | Registers a test user, verifies they get permissions |

All steps are **idempotent** — safe to run multiple times. If something exists, it's reused.

After setup, your credentials are in `credentials/`:

| File | What's in it | You'll need it for |
|---|---|---|
| `credentials/{service}.json` | Org ID, admin creds, API key | Backend config (`AB0T_AUTH_API_KEY`, `AB0T_AUTH_ORG_ID`) |
| `credentials/oauth-client.json` | OAuth client_id | Frontend SDK config |
| `credentials/hosted-login.json` | Login page URL, config snapshot | Reference |
| `credentials/end-users-org.json` | End-users org ID, slug, login URL, permissions | Frontend SDK config (org slug), backend (audience) |

These files are **gitignored** — never commit them.

### Step 6: Wire credentials into your app

**Frontend:**

```javascript
import { AuthMeshClient } from '@authmesh/sdk';

const auth = new AuthMeshClient({
  domain: 'https://auth.service.ab0t.com',
  org: '{org_slug from credentials/end-users-org.json}',
  clientId: '{client_id from credentials/oauth-client.json}',
  redirectUri: window.location.origin + '/auth/callback',
  scope: 'openid profile email',
});
```

**Backend:**

```python
from ab0t_auth import AuthGuard

guard = AuthGuard(
    auth_service_url="https://auth.service.ab0t.com",
    api_key="{api_key.key from credentials/{service}.json}",
    audience="{service_audience from credentials/{service}.json}",
)
```

### Step 7 (optional): Consume other mesh services

If your service needs to call other services' APIs (billing, payment, etc.):

```bash
# Create a config for each provider you want to consume
cp scripts/service-client-setup/clients.d/example.json.example \
   scripts/service-client-setup/clients.d/billing.json
# Edit clients.d/billing.json — set provider details and permissions you need

# Run step 07
./setup run 07
```

See `scripts/service-client-setup/README.md` for detailed instructions.

### Step 8 (optional): Let other services consume yours

If you want other mesh services to be able to call YOUR APIs:

```bash
# Optionally customize tier definitions first
cp config/api-consumers.json.example config/api-consumers.json
# Edit config/api-consumers.json — or skip this and it auto-generates from permissions.json

# Run step 08
./setup run 08
```

After this, other services self-register with two API calls. No approval needed.
See `scripts/service-client-setup/CONSUMER_SELF_SERVICE_GUIDE.md` for the full flow.

---

## Config File Summary

| File | Purpose | When to edit |
|---|---|---|
| `config/permissions.json` | Service identity, permissions, roles | Before step 01. This is your service's definition. |
| `config/oauth-client.json` | OAuth client for frontend auth | Before step 02. Set your redirect URIs. |
| `config/hosted-login.json` | Login page branding and settings | Before step 03. Set your brand colors and messages. |
| `config/api-consumers.json` | Consumer tier definitions | Before step 08 (optional). Auto-generates if missing. |
| `clients.d/{provider}.json` | Per-provider consumer config | Before step 07 (optional). One file per upstream service. |

## CLI Usage

```bash
./setup              # Interactive menu
./setup run          # Run all pending steps
./setup run 01       # Run a specific step
./setup status       # Show what's done and what's pending
./setup verify       # Run health checks (step 05)
./setup dry-run      # Preview without making changes
./setup help         # Show help
```

### Push protection

The repo ships a tracked git hook at `hooks/pre-push` that **refuses any
push from a clone where setup has been run** — i.e. one that contains
real `credentials/*.json`, working `config/*.json`, populated
`scripts/service-client-setup/clients.d/*.json`, or an `internal/`
directory.

The hook activates the first time you run `./setup` (which sets
`core.hooksPath=hooks` locally). Working clones therefore become
read-only with respect to the remote; to push fixes upstream, clone
fresh into a separate directory, apply your changes there, and push
from that clean clone.

Bypass for one-off pushes you've verified are safe: `git push --no-verify`.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `AUTH_SERVICE_URL` | `https://auth.service.ab0t.com` | Auth Mesh server URL |
| `DRY_RUN` | `0` | Set to `1` to preview without making changes |
| `ADMIN_EMAIL` | auto-generated | Override admin email (reads from credentials file if exists) |

### Targeting different environments

```bash
# Production (default)
./setup run

# Local development
AUTH_SERVICE_URL=http://localhost:8001 ./setup run
```

The CLI auto-detects the environment and uses separate credential files
(e.g., `service-dev.json` vs `service.json`).

## How It Works

Auth Mesh uses a Zanzibar-based permission model where **permissions are
inherited through organizational hierarchy**:

```
Service Org (your-service)                  <- admin, API key, permission schema
  |
  +-- End-Users Org (your-service-users)    <- users sign up HERE
        |   parent_id = service org
        |
        +-- Default Users Team              <- holds default_grant permissions
              |
              +-- User A (member) -> inherits team permissions
              +-- User B (member) -> inherits team permissions
```

When a user signs up via hosted login:
1. They join the end-users org as a `member`
2. They auto-join the Default Users team
3. They inherit all `default_grant: true` permissions through team membership
4. Zanzibar resolves this at permission-check time

No per-user grants. No callbacks. No cron jobs. No maintenance.

## Org Structures (`end_users.org_structure`)

The default behavior above (a single shared end-users pool) suits most services.
But some products want each user to have a private space — their own API keys,
their own teammates, their own settings. Think GitHub user namespaces, Notion
personal workspaces, or Vercel personal scopes.

You declare which structure you want in `permissions.json`:

```json
{
  "end_users": {
    "org_structure": {
      "pattern": "workspace-per-user"
    }
  }
}
```

The auth service has built-in event handlers that materialize the structure when
each user registers. Your backend writes no code.

### Available patterns

| Pattern | What happens on each new signup | When to use |
|---|---|---|
| `flat` (default) | User joins end-users org + default team. No extra orgs. | Public APIs, dev tools, internal dashboards. The user is using your shared service. |
| `workspace-per-user` | User joins end-users org + gets a private nested org under it where they are owner, with their own default team. | Per-user products (LLM gateway, sandbox platform, design tool) where each user manages their own resources, invites teammates, etc. |

### How to enable `workspace-per-user`

Two-line change in `permissions.json`:

```json
{
  "end_users": {
    "org_structure": {
      "pattern": "workspace-per-user"
    }
  }
}
```

Optional fine-tuning under `org_structure.config`:

```json
{
  "end_users": {
    "org_structure": {
      "pattern": "workspace-per-user",
      "config": {
        "slug_template": "{service_id}-{email_prefix}-{short_id}",
        "default_team_name": "Workspace Members"
      }
    }
  }
}
```

Then run `./setup run 04` (or `./setup run` for full setup). The CLI writes the
config into your end-users org's login_config; the auth service's handler reads
it at runtime.

### What each new user gets after enabling

```
End-Users Org (your-service-users)
  |
  +-- alice's workspace (settings.type = "user_workspace", owner = alice)
  |     +-- Default team (with your default_grant permissions)
  |     +-- alice (owner + team member)
  |
  +-- bob's workspace (settings.type = "user_workspace", owner = bob)
        +-- Default team
        +-- bob (owner + team member)
```

Each workspace is an org. The user is owner — they can invite teammates,
create more teams inside their workspace, manage their workspace settings.
They cannot see or modify other users' workspaces (cross-user isolation
enforced by the existing Zanzibar permission boundary).

### Backward compatibility

`org_structure` is fully optional. If you omit it, behavior is exactly what it
was before this feature existed — flat end-users pool with default team. Pure
auth-service deploys without setup-kit changes are zero-impact.

### Existing users when you enable later

If you switch a service from `flat` to `workspace-per-user` after some users
have already registered, the existing users do NOT get backfilled workspaces.
Only new signups (registration events fired AFTER the config change) get
workspaces. This is by design — login is not a creation trigger. If you need
to backfill, contact the platform team.

### What's coming (not in this release)

The `org_structure.pattern` enum is designed to grow. Patterns being explored:

- **`enterprise-on-billing-tier`** — when a user upgrades to an enterprise
  billing tier, automatically provision an enterprise customer org with them
  as owner. Triggered by billing events, not registration.
- **`workspace-plus-enterprise`** — combines `workspace-per-user` with the
  enterprise upgrade path.

These ship when the underlying triggers (billing service events) are wired up.
The schema enum will be extended additively — your existing config never
breaks.

### Implementation notes (for the curious)

The auth service runs an in-process event handler (`workspace_provisioning.py`)
that subscribes to `auth.user.registered`. The handler reads the org's
`login_config.registration.org_structure` and dispatches to a structure-specific
materializer. Each materializer uses existing org / team / membership APIs —
nothing about workspaces is a new primitive in the auth service. A workspace IS
an org, just nested with a settings tag.

This means: when you enable workspace-per-user, no new data shapes are
introduced. Existing tooling (org listing endpoints, hierarchy queries, audit
logs) sees the workspace orgs the same way they see any other nested org. The
only marker that distinguishes them is `settings.type = "user_workspace"` and
`settings.owner_user_id = <user_id>`.

## Setup Steps Reference

| Step | Script | Config Input | Credential Output |
|------|--------|---|---|
| 01 | `register-service-permissions.sh` | `permissions.json` | `{service}.json` |
| 02 | `register-oauth-client.sh` | `oauth-client.json` | `oauth-client.json` |
| 03 | `setup-hosted-login.sh` | `hosted-login.json` | `hosted-login.json` |
| 04 | `setup-default-team.sh` | `permissions.json` | `end-users-org.json` |
| 05 | `verify-setup.sh` | all credentials | -- |
| 06 | `test-end-user.sh` | `end-users-org.json` | -- |
| 07 | `register-consumer.sh` | `clients.d/*.json` | `{provider}-consumer.json` |
| 08 | `setup-api-consumers.sh` | `permissions.json` | `api-consumers.json` |

## Directory Structure

```
setup/
  setup                               CLI entry point
  README.md                           This file
  manifest.json                       File map with intents

  config/                             INPUT — edit these before running
    permissions.json                  Your service's permission schema
    permissions.json.example          Copy this to get started
    oauth-client.json                 OAuth client config
    oauth-client.json.example         Copy this to get started
    hosted-login.json                 Login page branding
    hosted-login.json.example         Copy this to get started
    api-consumers.json                Consumer tier definitions (step 08)
    api-consumers.json.example        Copy this to get started

  credentials/                        OUTPUT — generated by scripts (gitignored)
    {service}.json                    Step 01 output
    oauth-client.json                 Step 02 output
    hosted-login.json                 Step 03 output
    end-users-org.json                Step 04 output
    {provider}-consumer.json          Step 07 output
    api-consumers.json                Step 08 output

  scripts/                            Numbered setup scripts
    01-register-service-permissions.sh
    02-register-oauth-client.sh
    03-setup-hosted-login.sh
    04-setup-default-team.sh
    05-verify-setup.sh
    06-test-end-user.sh
    07-register-consumer.sh
    08-setup-api-consumers.sh
    service-client-setup/             Consumer/provider registration engines
      README.md                       Detailed consumer/provider guide
      CONSUMER_SELF_SERVICE_GUIDE.md  Self-service flow documentation
      register-as-client.sh           Co-located registration engine
      consumer-register.sh            Self-service registration engine
      provider-accept-consumer.sh     Per-consumer provider setup
      clients.d/                      Per-provider configs (gitignored)
        example.json.example          Config template

  schema/                             JSON Schema definitions
  Skills/                             Claude Code skill definitions
```

## Troubleshooting

### "Permission denied" when running scripts
```bash
chmod +x setup scripts/*.sh
```

### Users getting 403
1. Run `./setup verify` to check the setup
2. Ensure your frontend uses the **end-users org** login URL (from `credentials/end-users-org.json`), not the service org
3. Verify the `audience` in your backend matches `service_audience` from `credentials/{service}.json`
4. Check the user signed up through the hosted login page

### Step 01 fails with "Organization operation failed"
The org slug already exists. If you're re-running setup for an existing service,
make sure `credentials/{service}.json` exists with the previous run's output —
the script reads it to find the existing org.

### "Organization already exists"
Normal — all scripts are idempotent and reuse existing resources.

## Support

- Auth Mesh docs: https://auth.service.ab0t.com/docs
- Platform team: platform-team@ab0t.com
