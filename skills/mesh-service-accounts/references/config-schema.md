# Config Schema — clients.d/*.json

Each provider the consumer wants to call gets one JSON config file.

## Complete Schema

```json
{
    "provider": {
        "service_id": "billing",
        "service_name": "Billing Service",
        "credentials_path": "/absolute/path/to/billing/output/credentials/billing.json",
        "service_url": "http://localhost:8002"
    },
    "client": {
        "service_id": "sandbox-platform",
        "service_name": "Sandbox Platform",
        "customer_org_name": "Sandbox Platform - Billing Customer",
        "customer_org_slug": "billing-customer-sandbox-platform",
        "service_account_email": "sandbox-platform@billing.customers",
        "service_account_password": "CHANGE_ME_strong_password"
    },
    "permissions": [
        "billing.read",
        "billing.read.accounts",
        "billing.read.transactions",
        "billing.cross_tenant"
    ],
    "api_key": {
        "name": "sandbox-platform-billing-backend",
        "rate_limit": 10000,
        "metadata_purpose": "Backend API access for Sandbox Platform to proxy billing data on behalf of authenticated users"
    }
}
```

## Field Reference

### provider section

| Field | Required | Description |
|-------|----------|-------------|
| `service_id` | Yes | Provider's identifier in auth (matches their `permissions.json` service.id) |
| `service_name` | Yes | Human-readable name (displayed in logs and summaries) |
| `credentials_path` | Yes | **Absolute path** to provider's credential file (created by their `register-service-permissions.sh`). Contains admin email/password and org ID |
| `service_url` | Yes | Provider's API base URL. Used in output file for reference, not during registration |

### client section

| Field | Required | Description |
|-------|----------|-------------|
| `service_id` | Yes | Consumer's identifier |
| `service_name` | Yes | Consumer's display name |
| `customer_org_name` | Yes | Name for the sub-org created under the provider. Convention: `"{Consumer} - {Provider} Customer"` |
| `customer_org_slug` | Yes | URL-safe slug for the sub-org. Convention: `"{provider}-customer-{consumer}"`. Must be unique across auth |
| `service_account_email` | Yes | Email for the service account. Convention: `"{consumer}@{provider}.customers"`. Not a real email — just an identifier |
| `service_account_password` | Yes | Password for the service account. Only used during registration (login to create API key). Not used at runtime |

### permissions array

List of permission IDs the API key should carry. These must be permissions the provider has registered in auth.

Format: `{provider}.{action}.{resource}`

Common patterns:
- `billing.read` — base read access
- `billing.read.accounts` — read specific resource
- `billing.cross_tenant` — access data across orgs (essential for gateway services)

### api_key section

| Field | Required | Description |
|-------|----------|-------------|
| `name` | Yes | Human-readable key name. Convention: `"{consumer}-{provider}-backend"`. Shown in auth dashboard |
| `rate_limit` | Yes | Requests per hour. 10000 is a reasonable default for backend-to-backend calls |
| `metadata_purpose` | No | Description of what the key is used for. Stored in key metadata for auditing |

## Naming Conventions

```
customer_org_name:       "{Consumer Name} - {Provider Name} Customer"
customer_org_slug:       "{provider}-customer-{consumer}"
service_account_email:   "{consumer}@{provider}.customers"
api_key.name:            "{consumer}-{provider}-backend"
```

Examples for sandbox-platform consuming billing:
```
customer_org_name:       "Sandbox Platform - Billing Customer"
customer_org_slug:       "billing-customer-sandbox-platform"
service_account_email:   "sandbox-platform@billing.customers"
api_key.name:            "sandbox-platform-billing-backend"
```

Examples for analytics consuming payment:
```
customer_org_name:       "Analytics Service - Payment Customer"
customer_org_slug:       "payment-customer-analytics"
service_account_email:   "analytics@payment.customers"
api_key.name:            "analytics-payment-backend"
```

## File Location

```
<service>/setup/scripts/service-client-setup/
├── clients.d/
│   ├── billing.json      ← one file per provider
│   ├── payment.json
│   └── analytics.json
└── register-as-client.sh
```

The `07-register-consumer.sh` wrapper auto-discovers all `clients.d/*.json` files. Adding a new provider means creating one file — no script changes needed.
