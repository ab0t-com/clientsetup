# Service-to-Service Registration

> **INTENT:** This directory handles cross-service authentication in the mesh.
> Services call each other's APIs using scoped API keys. This directory contains
> the scripts and configs to set that up — both as a consumer and as a provider.

---

## Who Are You?

### "I need to call another service's API" → You are a CONSUMER

You want API keys to call upstream services (billing, payment, etc.).

**Your workflow:**
1. Create a config in `clients.d/<provider>.json` (see [Config Reference](#config-reference))
2. Run `./scripts/07-register-consumer.sh <provider>`
3. Set the API key in your `.env`

**Which engine to use:**

| Your situation | Engine | How it registers |
|---|---|---|
| **You and the provider are on the same machine** (co-located, single operator) | `register-as-client.sh` | Reads provider's credential file, logs in as provider admin, creates everything |
| **Provider is on a different machine / different team** | `consumer-register.sh` | Self-registers via provider's consumer org (provider must have run step 08 first) |
| **Provider gave you an invitation file** | `consumer-register.sh` | Uses the invitation file to find the right org and permissions |

Step 07 currently uses `register-as-client.sh`. To use the self-service flow instead,
run `consumer-register.sh` directly:

```bash
# Convention-based (provider ran step 08):
bash scripts/service-client-setup/consumer-register.sh billing

# Invitation-based (provider gave you a file):
bash scripts/service-client-setup/consumer-register.sh invitations/billing.invitation.json
```

---

### "I want other services to call MY API" → You are a PROVIDER

You want to let other mesh services register as consumers of your service.

**Two options:**

| Your situation | What to run | Result |
|---|---|---|
| **Open self-service registration** (any service can sign up) | Step 08: `./scripts/08-setup-api-consumers.sh` | Creates `{your-service}-api-consumers` org. Consumers self-register with two API calls, no approval needed. |
| **Controlled access** (approve each consumer individually) | `provider-accept-consumer.sh` | Creates a sub-org for one specific consumer. Outputs an invitation file you send to them. |

**Step 08 (self-service) is recommended** for most mesh services. It uses the same
Zanzibar auto-join pattern as step 04 (end-user registration) — consumers join a
permissions team automatically on signup.

---

## Quick Start: Consuming a Provider

### Prerequisites

- Your service has run step 01 (`register-service-permissions.sh`)
- Auth service is running and healthy
- The provider service is registered on the auth service

### Option A: Co-located (same machine)

```bash
# 1. Create config
cp clients.d/example.json.example clients.d/billing.json
# Edit clients.d/billing.json — set provider credentials path, permissions, etc.

# 2. Register
bash scripts/07-register-consumer.sh billing

# 3. Set in .env
BILLING_SERVICE_API_KEY=$(jq -r '.api_key.key' credentials/billing-consumer.json)
```

### Option B: Self-service (provider ran step 08)

```bash
# 1. Register (no config file needed — discovers by convention)
bash scripts/service-client-setup/consumer-register.sh billing

# 2. Set in .env
BILLING_SERVICE_API_KEY=$(jq -r '.api_key.key' \
  scripts/service-client-setup/credentials/billing-client.json)
```

### Option C: Manual (two API calls, no scripts)

```bash
# 1. Register
TOKEN=$(curl -s -X POST \
  $AUTH_SERVICE_URL/organizations/billing-api-consumers/auth/register \
  -H "Content-Type: application/json" \
  -d '{"email": "my-svc@billing.consumers", "password": "SecurePass2026!"}' \
  | jq -r '.access_token')

# 2. Create API key
curl -s -X POST $AUTH_SERVICE_URL/api-keys/ \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "my-svc-billing-key", "permissions": ["billing.read", "billing.cross_tenant"]}'
```

---

## Quick Start: Becoming a Provider

### Self-Service (step 08)

```bash
# From your service's setup directory
./scripts/08-setup-api-consumers.sh
```

This creates:
```
Your Service Org
└── {service}-api-consumers (child org)
    ├── "Read-Only Consumers" team (DEFAULT — auto-join)
    │   └── [read permissions + cross_tenant]
    ├── "Standard Consumers" team (upgrade tier)
    │   └── [read + safe writes + cross_tenant]
    └── Login config: signup_enabled=true, default_team=Read-Only
```

After this, any service can self-register by calling two endpoints. No involvement
from you. See the [Consumer Self-Service Guide](CONSUMER_SELF_SERVICE_GUIDE.md) for
the full provider setup and consumer onboarding flow.

### Per-Consumer (controlled access)

```bash
bash scripts/service-client-setup/provider-accept-consumer.sh clients.d/consumer-name.json
# Outputs: invitations/provider-consumer.invitation.json
# Send the invitation file to the consumer team
```

---

## Config Reference

### clients.d/*.json

One file per upstream provider. Declares what your service needs from them.

```json
{
    "provider": {
        "service_id": "billing",
        "service_name": "Billing Service",
        "credentials_path": "/path/to/billing/credentials/billing.json",
        "service_url": "http://localhost:8002"
    },
    "client": {
        "service_id": "your-service",
        "service_name": "Your Service Name",
        "customer_org_name": "Your Service - Billing Customer",
        "customer_org_slug": "billing-customer-your-service",
        "service_account_email": "your-service@billing.customers",
        "service_account_password": "CHANGE_ME_strong_password"
    },
    "permissions": [
        "billing.read",
        "billing.read.accounts",
        "billing.cross_tenant"
    ],
    "api_key": {
        "name": "your-service-billing-backend",
        "rate_limit": 10000,
        "metadata_purpose": "Backend API access to proxy billing data"
    }
}
```

| Field | Used by | Notes |
|---|---|---|
| `provider.credentials_path` | `register-as-client.sh` only | Not needed for self-service flow |
| `client.service_account_password` | `register-as-client.sh` only | Not needed for self-service flow (auto-generated) |
| `permissions` | Both engines | What permissions your API key should carry |

### Naming Conventions

```
customer_org_name:       "{Your Service} - {Provider} Customer"
customer_org_slug:       "{provider}-customer-{your-service}"
service_account_email:   "{your-service}@{provider}.customers"
api_key.name:            "{your-service}-{provider}-backend"
```

---

## Output Files

Registration produces a credential file (gitignored):

```json
{
    "provider": {
        "service_id": "billing",
        "service_name": "Billing Service",
        "service_url": "http://localhost:8002"
    },
    "customer_org": {
        "id": "...",
        "name": "Your Service - Billing Customer",
        "slug": "billing-customer-your-service"
    },
    "service_account": {
        "email": "your-service@billing.customers",
        "user_id": "..."
    },
    "api_key": {
        "id": "...",
        "key": "ab0t_sk_live_...",
        "permissions": ["billing.read", "billing.cross_tenant"]
    },
    "created_at": "2026-03-13T..."
}
```

Wire the API key into your app:
```bash
# In .env
BILLING_SERVICE_API_KEY=$(jq -r '.api_key.key' credentials/billing-consumer.json)

# In code — send as X-API-Key header
request_headers["X-API-Key"] = settings.BILLING_SERVICE_API_KEY
```

---

## How Permissions Flow (Self-Service)

```
Consumer registers at /organizations/billing-api-consumers/auth/register
        |
        v
Auth server reads login config:
  default_role = service_account    <- gives api.read, api.write (ONLY)
  default_team = Read-Only team     <- gives billing.read.*, billing.cross_tenant
        |
        v
Zanzibar writes:
  user:{consumer}#member@team:{read-only-team}
        |
        v
Consumer creates API key:
  POST /api-keys/ { permissions: ["billing.read", ...] }
  Server checks: requested <= effective -> PASS
  Server checks: billing.admin <= effective -> FAIL (403)
```

---

## Upgrading a Consumer's Tier

When a consumer needs write access, the provider admin moves them to a higher tier:

```bash
# Provider admin adds consumer to Standard team
curl -X POST $AUTH_SERVICE_URL/teams/{standard-team-id}/members \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"user_id": "<consumer-user-id>", "role": "member"}'
```

Consumer creates a new API key with broader permissions (old key still works).

---

## Adding a New Provider

```bash
# 1. Copy example config
cp clients.d/example.json.example clients.d/analytics.json

# 2. Edit — set provider details, permissions, service account
vim clients.d/analytics.json

# 3. Register
bash scripts/07-register-consumer.sh analytics

# 4. Add API key to .env
ANALYTICS_SERVICE_API_KEY=$(jq -r '.api_key.key' credentials/analytics-consumer.json)

# 5. Rebuild
docker compose up -d --build
```

---

## Troubleshooting

### "Provider credentials not found"
The provider's credential file isn't at the path in `clients.d/<provider>.json`.
Either fix the path, or use `consumer-register.sh` (self-service flow — no provider
credentials needed).

### "Registration is disabled for this organization"
The provider hasn't run step 08 (`08-setup-api-consumers.sh`), or `signup_enabled`
is false in their consumer org login config.

### API calls return 401
API key not being sent. Verify: `curl -H "X-API-Key: $KEY" $URL/health`

### API calls return 403
Wrong permissions. Check: `jq '.api_key.permissions' credentials/<provider>-consumer.json`

### After a DB wipe
DynamoDB local loses everything on container restart:
1. Delete stale credential files: `rm -f credentials/*-consumer.json`
2. Re-register your service: `bash scripts/01-register-service-permissions.sh`
3. Re-register as consumer: `bash scripts/07-register-consumer.sh`
4. Update `.env` with new API keys and rebuild

---

## File Layout

```
scripts/
├── 07-register-consumer.sh               <- Step 07: register as CONSUMER (iterates providers)
├── 08-setup-api-consumers.sh             <- Step 08: set up as PROVIDER (self-service)
│
└── service-client-setup/
    ├── README.md                          <- This file
    ├── CONSUMER_SELF_SERVICE_GUIDE.md     <- Deep dive: self-service flow (step 08 + consumer-register)
    │
    ├── register-as-client.sh              <- Engine: co-located flow (needs provider creds on disk)
    ├── consumer-register.sh               <- Engine: self-service flow (org-scoped, no provider creds)
    ├── provider-accept-consumer.sh        <- Engine: per-consumer provider setup (outputs invitation)
    │
    ├── clients.d/
    │   ├── example.json.example           <- Config template
    │   ├── billing.json                   <- (gitignored) Your billing consumer config
    │   └── payment.json                   <- (gitignored) Your payment consumer config
    │
    ├── credentials/
    │   └── .gitignore                     <- Blocks *.json (API keys)
    │
    └── invitations/
        └── .gitignore                     <- Blocks *.json (invitation files)
```
