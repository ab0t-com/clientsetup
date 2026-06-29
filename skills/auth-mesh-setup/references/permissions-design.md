# Permission Design — permissions.json

The permission config is the source of truth for what your service can do and who can do it.

## Complete Schema

```json
{
  "$schema": "https://auth.service.ab0t.com/schemas/permissions/v2",
  "service": {
    "id": "sandbox-platform",
    "name": "Sandbox Platform",
    "description": "Cloud sandbox provisioning and management",
    "version": "1.0.0",
    "audience": "sandbox-platform",
    "maintainer": "platform-team@ab0t.com"
  },
  "registration": {
    "service": "sandbox",
    "actions": ["create", "read", "write", "delete", "execute", "manage", "admin"],
    "resources": ["sandboxes", "commands", "files", "metrics", "costs", "containers", "browsers", "desktops", "ssh_keys"]
  },
  "permissions": [
    {
      "id": "sandbox.create.sandboxes",
      "name": "Create Sandbox",
      "description": "Allows user to create new sandboxes",
      "intent": "Core feature — every user needs this",
      "risk_level": "medium",
      "cost_impact": true,
      "default_grant": true,
      "scope": "user"
    },
    {
      "id": "sandbox.admin",
      "name": "Admin Access",
      "description": "Full admin access to all sandbox operations",
      "risk_level": "critical",
      "default_grant": false,
      "implies": ["sandbox.create.sandboxes", "sandbox.read.sandboxes", "sandbox.write.sandboxes", "sandbox.delete.sandboxes"]
    }
  ],
  "roles": [
    {
      "id": "sandbox-user",
      "name": "Sandbox User",
      "description": "Standard user with default permissions",
      "permissions": ["sandbox.create.sandboxes", "sandbox.read.sandboxes"],
      "default": true
    }
  ],
  "multi_tenancy": {
    "isolation_model": "organization",
    "tenant_field": "org_id",
    "enforcement": "strict",
    "cross_tenant_permission": "sandbox.cross_tenant"
  },
  "end_users": {
    "auto_provision": false,
    "default_role": "sandbox-user",
    "default_team_name": "Default Users",
    "provision_via": "default_team"
  }
}
```

## Field Reference

### service section

| Field | Required | Description |
|-------|----------|-------------|
| `id` | Yes | Unique service ID. Must match `^[a-z][a-z0-9-]*$`. Used in org slugs, API keys, and as the permission namespace prefix |
| `name` | Yes | Human-readable display name |
| `description` | Yes | What the service does |
| `version` | No | Semver version of the permission schema |
| `audience` | Yes | RFC 9068 audience string for JWT validation. Stored on org record via `service_audience` field |
| `maintainer` | No | Contact email |

### registration section

| Field | Required | Description |
|-------|----------|-------------|
| `service` | Yes | Permission namespace prefix (usually matches `service.id` minus hyphens). All permission IDs must start with `{service}.` |
| `actions` | Yes | Verbs your service supports (read, write, create, delete, execute, admin, manage, cross_tenant) |
| `resources` | Yes | Nouns your service manages (sandboxes, commands, files, metrics). Combined with actions to form permission IDs |

### permissions array

| Field | Required | Description |
|-------|----------|-------------|
| `id` | Yes | Format: `{service}.{action}.{resource}` or `{service}.{action}`. Must match registered actions/resources |
| `name` | Yes | Human-readable name |
| `description` | Yes | What this permission allows |
| `intent` | No | Why users need this (for PMM/docs) |
| `risk_level` | No | `low`, `medium`, `high`, `critical` |
| `cost_impact` | No | Boolean — does this permission trigger billable actions? |
| `default_grant` | Yes | **If `true`**: auto-granted to new users via team membership. **If `false`**: requires explicit admin grant |
| `scope` | No | `user` (own resources), `org` (org resources), `cross_org` (any org) |
| `implies` | No | Array of permission IDs. When this permission is granted, implied ones are too (admin use case) |
| `security_notes` | No | Notes about security considerations |

### roles array

| Field | Required | Description |
|-------|----------|-------------|
| `id` | Yes | Role identifier |
| `name` | Yes | Display name |
| `permissions` | Yes | Permission IDs this role includes |
| `default` | No | If `true`, this is the default role for self-registered users |

### end_users section

| Field | Description |
|-------|-------------|
| `default_team_name` | Name for the auto-join team (default: "Default Users") |
| `default_role` | Role assigned to new users on registration |
| `provision_via` | How permissions flow: `"default_team"` = team membership |

## Design Principles

### default_grant: true vs false

```
default_grant: true   →  Every user gets this via team membership
                          Use for: core features all users need
                          Examples: read own sandboxes, create sandboxes, view costs

default_grant: false  →  Admin must explicitly grant
                          Use for: admin operations, dangerous actions, cross-tenant access
                          Examples: admin, delete all, cross_tenant, manage SSH keys
```

### Permission ID Format

```
{service}.{action}                    sandbox.admin
{service}.{action}.{resource}         sandbox.create.sandboxes
```

- `service` = lowercase, no underscores (use the registration.service value)
- `action` = verb (read, write, create, delete, execute, manage, admin, cross_tenant)
- `resource` = plural noun with underscores allowed (sandboxes, ssh_keys, payment_methods)

### The implies Chain

For admin-level permissions that subsume others:

```json
{
  "id": "sandbox.admin",
  "default_grant": false,
  "implies": [
    "sandbox.create.sandboxes",
    "sandbox.read.sandboxes",
    "sandbox.write.sandboxes",
    "sandbox.delete.sandboxes",
    "sandbox.execute.commands"
  ]
}
```

Step 01 grants all `implies` permissions to the admin user during registration.

### Multi-Tenancy

- `isolation_model: "organization"` — resources belong to orgs, not individual users
- `tenant_field: "org_id"` — the field in your DB that identifies the owning org
- `enforcement: "strict"` — every data access must check org_id matches
- `cross_tenant_permission` — permission ID that allows cross-org access (for service accounts / admin)
