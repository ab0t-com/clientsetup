# Consumer Self-Service Registration Guide

> **INTENT:** This documents the SELF-SERVICE flow where consumers register
> without needing provider credentials. The provider runs step 08 once to
> create a consumer org. After that, any service self-registers with two
> API calls — no provider involvement.
>
> This is the recommended flow for multi-team deployments. For co-located
> single-operator deployments, `register-as-client.sh` is a simpler alternative.

How mesh services register as consumers of other services. Two API calls,
zero provider involvement after initial setup.

---

## How It Works

```
PROVIDER (one-time setup)                CONSUMER (any time, self-service)
─────────────────────────                ─────────────────────────────────

  08-setup-api-consumers.sh                Two API calls:
  ┌─────────────────────────┐
  │ Creates:                │              1. POST /organizations/
  │   {svc}-api-consumers   │                 {svc}-api-consumers/
  │     └── Read-Only team  │                 auth/register
  │         └── [perms]     │                 { email, password }
  │     └── Standard team   │                 → auto-joins team
  │         └── [perms]     │                 → inherits permissions
  │     └── login config:   │
  │         default_team    │              2. POST /api-keys/
  │         default_role:   │                 { name, permissions }
  │         service_account │                 → returns API key
  └─────────────────────────┘
                                           Done. Set API key in .env.
  After this, the provider
  never needs to do anything
  for new consumers.
```

The same Zanzibar mechanism that gives end-users their permissions
(step 04 — team auto-join) gives service accounts their permissions.

---

## For Providers: Setting Up Consumer Registration

### Prerequisites

- Step 01 has been run (service org + permissions registered)
- `config/permissions.json` (or `.permissions.json`) exists

### Run Step 08

```bash
# From your service's setup directory
./scripts/08-setup-api-consumers.sh

# Or with explicit paths (for services without setup/ structure)
SETUP_DIR=. \
PERMISSIONS_FILE=.permissions.json \
AUTH_SERVICE_URL=http://localhost:8001 \
bash /path/to/08-setup-api-consumers.sh
```

The script:
1. Auto-generates `config/api-consumers.json` from your permissions (if it doesn't exist)
2. Creates `{service}-api-consumers` child org under your service org
3. Creates "Read-Only Consumers" team (all read + cross_tenant permissions)
4. Creates "Standard Consumers" team (read + safe writes)
5. Configures login: `default_role=service_account`, `default_team=read-only`
6. Saves to `credentials/api-consumers.json`

### What Gets Created

```
Your Service Org (e.g., billing)
└── billing-api-consumers (child org)
    ├── "Read-Only Consumers" team (DEFAULT — auto-join)
    │   └── billing.read, billing.read.accounts, billing.read.transactions,
    │       billing.read.usage, billing.read.reports, billing.read.reservations,
    │       billing.read.financial_reports, billing.cross_tenant
    │
    ├── "Standard Consumers" team
    │   └── (all read + billing.write.reservations + cross_tenant)
    │
    └── Login config:
        ├── default_role: service_account  ← minimal role (only api.read, api.write)
        ├── default_team: Read-Only team   ← auto-join on registration
        └── signup_enabled: true           ← self-service open
```

### Customizing Tiers

Edit `config/api-consumers.json` before running step 08:

```json
{
    "tiers": [
        {
            "name": "Read-Only Consumers",
            "default": true,
            "permissions": ["billing.read", "billing.read.accounts", "billing.cross_tenant"]
        },
        {
            "name": "Standard Consumers",
            "default": false,
            "permissions": ["billing.read", "billing.write.reservations", "billing.cross_tenant"]
        }
    ]
}
```

Or let the script auto-generate it from `permissions.json`.

---

## For Consumers: Registering with a Provider

### Option 1: Convention-Based (Recommended)

```bash
# Just the provider name — discovers everything by convention
bash consumer-register.sh billing
bash consumer-register.sh payment
```

The script:
1. Derives the consumer org slug: `billing-api-consumers`
2. Registers via `POST /organizations/billing-api-consumers/auth/register`
3. Auto-joins the "Read-Only Consumers" team
4. Discovers permissions from team membership
5. Creates API key with those permissions
6. Saves to `credentials/billing-client.json`

### Option 2: Invitation-Based

If the provider gave you an invitation file:

```bash
bash consumer-register.sh invitations/billing-sandbox-platform.invitation.json
```

### Option 3: Manual (Two API Calls)

No scripts needed:

```bash
# 1. Register
TOKEN=$(curl -s -X POST \
  https://auth.service.ab0t.com/organizations/billing-api-consumers/auth/register \
  -H "Content-Type: application/json" \
  -d '{"email": "my-svc@billing.consumers", "password": "SecurePass2026!"}' \
  | jq -r '.access_token')

# 2. Create API key (permissions auto-inherited from team)
curl -s -X POST https://auth.service.ab0t.com/api-keys/ \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "my-svc-billing-key",
    "permissions": ["billing.read", "billing.read.accounts", "billing.cross_tenant"]
  }'
```

### After Registration

Set the API key in your service's `.env`:

```env
BILLING_SERVICE_URL=http://host.docker.internal:8002
BILLING_SERVICE_API_KEY=ab0t_sk_live_...
```

Rebuild:
```bash
docker compose up -d --build
```

---

## How Permissions Flow

```
Consumer registers at /organizations/billing-api-consumers/auth/register
        │
        ▼
Auth server reads login config:
  default_role = service_account    ← gives api.read, api.write (ONLY)
  default_team = Read-Only team     ← gives billing.read.*, billing.cross_tenant
        │
        ▼
Zanzibar writes:
  user:{consumer-sa}#member@team:{read-only-team}
        │
        ▼
Permission resolution:
  role permissions:     [api.read, api.write]           ← from service_account role
  team permissions:     [billing.read, billing.read.accounts, ...]  ← from team
  effective:            union of both
        │
        ▼
Consumer creates API key:
  POST /api-keys/ { permissions: ["billing.read", ...] }
  Server checks: requested ⊆ effective → PASS
  Server checks: billing.admin ⊆ effective → FAIL (403)
```

---

## Security Model

### What the `service_account` Role Prevents

| Action | `member` role (old) | `service_account` role (new) |
|--------|--------------------|-----------------------------|
| List org users | Yes (`users.read`) | **No** → 403 |
| List team members | Yes (`teams.read`) | **No** → 403 |
| Create child orgs | Yes (no permission check) | **No** → 403 (parent gate) |
| Modify org settings | No (`org.admin` required) | No |
| Modify team permissions | No (`teams.write` required) | No |
| Create API key with `billing.admin` | Yes (no subset check) | **No** → 403 (subset check) |
| Create API key with `billing.read` | Yes | Yes (team grants it) |

### Three Defense Layers

1. **`service_account` role** — no `users.read`, `teams.read`, or `org.read`
2. **Permission subset enforcement** — API key permissions ⊆ caller's effective permissions
3. **Parent org gate** — child org creation requires `org.admin` on the parent

Each layer independently blocks the attack chain. All three together provide
defense in depth.

---

## Upgrading a Consumer's Tier

When a consumer needs write access:

```bash
# Provider admin adds consumer to Standard team
curl -X POST https://auth.service.ab0t.com/teams/{standard-team-id}/members \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"user_id": "<consumer-user-id>", "role": "member"}'
```

Consumer creates a new API key with the broader permissions:

```bash
curl -X POST https://auth.service.ab0t.com/api-keys/ \
  -H "Authorization: Bearer $CONSUMER_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "my-svc-billing-write", "permissions": ["billing.read", "billing.write.reservations"]}'
```

---

## Naming Conventions

```
Consumer org slug:     {service}-api-consumers
Service account email: {consumer}@{provider}.consumers
API key name:          {consumer}-{provider}-backend
Credential file:       credentials/{provider}-client.json
```

---

## Troubleshooting

### "Registration is disabled for this organization"

The provider hasn't run `08-setup-api-consumers.sh`, or `signup_enabled` is
false in the login config.

### API key creation returns 403

The requested permissions exceed what your team grants. Check your effective
permissions:

```bash
curl -s https://auth.service.ab0t.com/permissions/user/{your_user_id}?org_id={consumer_org_id} \
  -H "Authorization: Bearer $TOKEN" | jq .permissions
```

Only request permissions that appear in this list.

### "Organization not found" on registration

The consumer org slug is wrong. Convention: `{service}-api-consumers`.
Check the provider's `credentials/api-consumers.json` for the correct slug.

### No permissions after registration

Team auto-join may not have triggered. Check:
1. Login config has `default_team` set
2. Login config has `default_role: "service_account"` (not `"member"`)
3. The team has permissions assigned

Re-run `08-setup-api-consumers.sh` on the provider side to fix.
