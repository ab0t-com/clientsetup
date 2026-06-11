# Mesh Topology

How services, orgs, audiences, and API keys relate in the ab0t auth mesh.

## The Mesh

The ab0t mesh is a network of independent services that share a common auth service for identity, permissions, and API key validation. Each service is a standalone product — any mesh participant can consume any other.

```
                    Auth Service
                   (shared identity)
                    /    |     \
                   /     |      \
            Billing   Payment   Resource   Sandbox   Integration  ...
            (8002)    (8005)    (8007)     (8020)    (8009)
```

Currently co-located on a single server, designed to be distributed.

## Service Registration

Each service registers with auth via `register-service-permissions.sh`:

1. Creates a **service org** (e.g., `billing` org `7552d363...`)
2. Creates an **admin account** (e.g., `mike+billing@ab0t.com`)
3. Registers **permissions** (e.g., `billing.read`, `billing.write.*`)
4. Gets a **service API key** for server-to-auth calls
5. Saves credentials to `credentials/<service>.json`

Some services also create an **end-users org** (child of service org) for user self-registration.

## Audience Enforcement

Each service sets `AB0T_AUTH_AUDIENCE` to a unique value:

| Service | Audience | Env Var |
|---------|----------|---------|
| Billing | `billing-service` | `AB0T_AUTH_AUDIENCE=billing-service` |
| Payment | `payment-service` | `AB0T_AUTH_AUDIENCE=payment-service` |
| Resource | `LOCAL:<org_id>` | (derived from org) |
| Sandbox Platform | `sandbox-platform` | (derived from org) |
| Integration | `integration-service` | (derived from org) |

With `AB0T_AUTH_AUDIENCE_SKIP=false` (required for mesh security), JWTs are only valid for the service they were issued for. A user's JWT for sandbox-platform (`aud=sandbox-platform`) is rejected by billing (`aud=billing-service`).

This is why cross-service calls use **API keys**, not JWTs. API keys bypass audience checks.

## Two Auth Modes

The auth library (`ab0t_auth` / AuthGuard) supports two authentication modes:

### JWT Authentication (user → service)

```
Browser → Service
  Authorization: Bearer <JWT>
  │
  Service validates JWT:
    1. Verify signature via JWKS
    2. Check audience matches service
    3. Check permissions
    4. Run check callbacks (belongs_to_org, etc.)
    5. Return AuthenticatedUser
```

### API Key Authentication (service → service)

```
Consumer Service → Provider Service
  X-API-Key: ab0t_sk_live_...
  │
  Provider validates via auth service:
    POST /auth/validate-api-key { api_key: "ab0t_sk_live_..." }
    → { valid: true, permissions: [...], user_id, org_id }
```

Both modes are enabled with:
```env
AB0T_AUTH_ENABLE_API_KEY_AUTH=true
AB0T_AUTH_API_KEY_HEADER=X-API-Key
```

## The Gateway Pattern

When a service proxies data from upstream services to its users:

```
User (browser)
  │
  │  JWT (aud=sandbox-platform)
  │  GET /api/billing/balance
  v
Sandbox Platform (port 8020)
  │  AuthGuard validates JWT
  │  Extracts org_id from JWT claims
  │
  │  API Key (X-API-Key: ab0t_sk_live_...)
  │  GET /billing/{org_id}/balance
  v
Billing Service (port 8002)
  │  AuthGuard validates API key via auth service
  │  Checks billing.read.accounts permission
  │  Checks billing.cross_tenant permission
  │  Returns data for the requested org_id
  v
Response flows back through sandbox-platform to browser
```

The gateway pattern means:
- User authenticates with their service's audience
- Gateway extracts org_id from JWT (not from request params)
- Gateway calls upstream with its own consumer API key
- Upstream validates the API key and checks permissions
- Error details stay server-side

## Org Hierarchy for Consumer Registration

```
Auth Service
│
├── Billing Org (provider)
│   ├── billing.* permissions
│   └── Sandbox Platform - Billing Customer (sub-org)
│       └── sandbox-platform@billing.customers (service account)
│           └── API key: billing.read.*, billing.cross_tenant
│
├── Payment Org (provider)
│   ├── payment.* permissions
│   └── Sandbox Platform - Payment Customer (sub-org)
│       └── sandbox-platform@payment.customers (service account)
│           └── API key: payment.read.*, payment.cross_org
│
├── Sandbox Platform Org
│   ├── sandbox.* permissions
│   └── Sandbox Platform Users (end-users org)
│       └── users sign up here
│
└── (other services...)
```

Each consumer sub-org is scoped under the provider's org tree. The provider admin retains full control. The consumer only has the API key.

## Cross-Tenant Permissions

Consumer API keys need `cross_tenant` (or `cross_org`) permission because the consumer serves users from many different orgs through a single API key. Without it, the key can only access data belonging to the sub-org itself.

With `billing.cross_tenant`, the consumer can call `GET /billing/{any_org_id}/balance` and the billing service allows it because the API key carries the cross-tenant permission.

The org_id in the request comes from the user's validated JWT — not from the API key's org. This is what makes the gateway pattern work: one API key, many user orgs.

## Environment Variables (Universal)

Every mesh service should have these in its `.env`:

```env
# Auth connection
AB0T_AUTH_AUTH_URL=https://auth.service.ab0t.com    # or AB0T_AUTH_URL
AB0T_AUTH_AUDIENCE=<service-specific-audience>
AB0T_AUTH_AUDIENCE_SKIP=false                        # MUST be false for mesh security

# API key support (for receiving cross-service calls)
AB0T_AUTH_ENABLE_API_KEY_AUTH=true
AB0T_AUTH_API_KEY_HEADER=X-API-Key
```

And passed through in `docker-compose.yml`:

```yaml
environment:
  - AB0T_AUTH_URL=${AB0T_AUTH_URL:-https://auth.service.ab0t.com}
  - AB0T_AUTH_AUDIENCE=${AB0T_AUTH_AUDIENCE}
  - AB0T_AUTH_AUDIENCE_SKIP=${AB0T_AUTH_AUDIENCE_SKIP:-false}
  - AB0T_AUTH_ENABLE_API_KEY_AUTH=${AB0T_AUTH_ENABLE_API_KEY_AUTH:-true}
  - AB0T_AUTH_API_KEY_HEADER=${AB0T_AUTH_API_KEY_HEADER:-X-API-Key}
```
