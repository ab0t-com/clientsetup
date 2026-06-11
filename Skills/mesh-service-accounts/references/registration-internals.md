# Registration Internals

What `register-as-client.sh` does in each of its 8 steps, including the auth API calls made.

## Prerequisites

- Auth service running and healthy
- Provider has run `register-service-permissions.sh` (creates org, admin, permissions)
- `jq` and `curl` available

## Step-by-Step

### Step 1: Load Provider Credentials

Reads the provider's credential file (path from `clients.d/<provider>.json` → `provider.credentials_path`).

Extracts:
- `admin.email` — provider admin login
- `admin.password` — provider admin password
- `organization.id` — provider org UUID

If `PROVIDER_CREDS` env var is set, uses that path instead.

### Step 2: Login as Provider Admin

```
POST /auth/login
  { email, password }
→ { access_token }

POST /auth/switch-organization
  { org_id: <provider_org_id> }
→ { access_token }  (org-scoped token)
```

The org-scoped token is needed because the admin may belong to multiple orgs. The switch ensures all subsequent operations happen in the provider's org context.

### Step 3: Create Customer Sub-Org

First checks if the sub-org already exists:

```
GET /users/me/organizations
→ [ { id, name, slug }, ... ]
```

Searches by `customer_org_name`. If found, reuses it.

If not found, creates it:

```
POST /organizations/
  {
    name: "Sandbox Platform - Billing Customer",
    slug: "billing-customer-sandbox-platform",
    parent_id: "<provider_org_id>",
    billing_type: "enterprise",
    settings: {
      type: "customer_account",
      parent_service: "billing",
      customer_service_id: "sandbox-platform",
      customer_name: "Sandbox Platform"
    }
  }
→ { id: "<customer_org_id>" }
```

The `parent_id` makes this a child org of the provider org. The `settings` metadata is for auditing — it records who this sub-org was created for.

### Step 4: Create Service Account

Registers a new user account for the service:

```
POST /auth/register
  {
    email: "sandbox-platform@billing.customers",
    password: "<from-config>",
    name: "Sandbox Platform Service Account"
  }
→ { access_token, user: { id } }
```

If the account already exists (409), logs in instead:

```
POST /auth/login
  { email, password }
→ { access_token, user: { id } }
```

The email is not a real email — it's a convention for identifying service accounts: `{consumer}@{provider}.customers`.

### Step 5: Add Service Account to Customer Org

Switches provider admin to the customer org context:

```
POST /auth/switch-organization
  { org_id: "<customer_org_id>" }
→ { access_token }
```

Then invites the service account:

```
POST /organizations/<customer_org_id>/invite
  { email: "sandbox-platform@billing.customers", role: "admin" }
→ { user_id }
```

The service account gets `admin` role in the customer sub-org so it can create API keys.

If already a member, the invite is silently skipped.

### Step 6: Get Org-Scoped Token for Service Account

Logs in the service account and switches to the customer org:

```
POST /auth/login
  { email, password }
→ { access_token }

POST /auth/switch-organization
  { org_id: "<customer_org_id>" }
→ { access_token }  (org-scoped token for service account)
```

This org-scoped token is used to create the API key in the next step. The key inherits the org context from the token.

### Step 7: Create API Key

```
POST /api-keys/
  {
    name: "sandbox-platform-billing-backend",
    permissions: ["billing.read", "billing.read.accounts", ...],
    rate_limit: 10000,
    metadata: {
      client_service: "sandbox-platform",
      provider_service: "billing",
      customer_org: "<customer_org_id>",
      purpose: "Backend API access for..."
    }
  }
→ { id, key: "ab0t_sk_live_...", permissions: [...] }
```

The `key` field contains the full API key — this is the only time it's returned in plaintext. It's stored in the output file.

### Step 8: Save Credentials

Writes a JSON file to `credentials/<provider>-client.json`:

```json
{
    "provider": {
        "service_id": "billing",
        "service_name": "Billing Service",
        "service_url": "http://localhost:8002",
        "root_org_id": "<provider_org_id>"
    },
    "customer_org": {
        "id": "<customer_org_id>",
        "name": "Sandbox Platform - Billing Customer",
        "slug": "billing-customer-sandbox-platform",
        "parent_org": "<provider_org_id>"
    },
    "service_account": {
        "email": "sandbox-platform@billing.customers",
        "password": "<password>",
        "user_id": "<user_id>"
    },
    "api_key": {
        "id": "<key_id>",
        "key": "ab0t_sk_live_...",
        "permissions": ["billing.read", ...]
    },
    "created_at": "2026-03-13T..."
}
```

## Idempotency

- **Sub-org**: reused if name matches
- **Service account**: reused if email exists (login instead of register)
- **Org membership**: silently skipped if already a member
- **API key**: new key created each run (old keys remain valid)

## The 07-register-consumer.sh Wrapper

The wrapper script:
1. Auto-discovers all `clients.d/*.json` files
2. Runs `register-as-client.sh` for each provider
3. Copies output to `credentials/<provider>-consumer.json`
4. Prints API keys to set in `.env`
5. Reports PASS/FAIL summary

Can target specific providers: `07-register-consumer.sh billing payment`
