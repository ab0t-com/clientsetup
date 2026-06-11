---
name: mesh-service-accounts
description: Register services as consumers of other services in the ab0t auth mesh network. Use when a service needs to call another service's API (cross-service calls), when setting up service-to-service authentication via API keys, when creating consumer service accounts and sub-orgs under provider services, when designing permissions for cross-service access, when writing clients.d config files, when running register-as-client.sh or 07-register-consumer.sh, when wiring up X-API-Key headers for mesh calls, when debugging 401/403 errors on cross-service requests, or when adding a new upstream provider to an existing consumer. Covers the full consumer registration lifecycle from permission design through config, registration, API key provisioning, client code, proxy routes, and env wiring.
---

# Mesh Service Accounts

Register one service as a **consumer** of another service in the ab0t auth mesh.

## Core Concept

Services in the mesh have separate orgs and separate JWT audiences. Service A's user JWT (`aud=service-a`) is rejected by Service B (`aud=service-b`). To make cross-service calls, the consumer registers a **service account** under the provider, gets its own **API key** with scoped permissions, and sends that key via `X-API-Key` header.

```
Consumer Service                          Provider Service
  │                                            │
  │  user JWT → validate locally               │
  │  extract org_id from JWT claims             │
  │                                            │
  │  X-API-Key: ab0t_sk_live_...  ────────────>│
  │  GET /provider/{org_id}/resource            │
  │                                            │
  │                          provider validates │
  │                          key via auth svc   │
  │                          checks permissions │
  │                                            │
  │  200 { data }  <───────────────────────────│
```

## Auth Structure Created

```
Auth Service
└── Provider Org (e.g. billing)
    └── Consumer - Provider Customer (sub-org, child of provider)
        └── consumer@provider.customers (service account)
            └── API key: provider.read.*, provider.cross_tenant
```

The provider admin creates and controls the sub-org. The consumer only receives the API key.

## Workflow

### Adding a new provider to a consumer service

1. **Verify provider is registered** — provider must have run `register-service-permissions.sh`
2. **Create config** — write `clients.d/<provider>.json`. See [references/config-schema.md](references/config-schema.md)
3. **Run registration** — `bash 07-register-consumer.sh <provider>`
4. **Wire API key** — add `<PROVIDER>_SERVICE_API_KEY` to `.env` and `docker-compose.yml`
5. **Write client code** — create `app/<provider>_client.py`. See [references/client-patterns.md](references/client-patterns.md)
6. **Add proxy routes** — wire routes in `main.py`. See [references/proxy-routes.md](references/proxy-routes.md)
7. **Rebuild and test**

### Building a new consumer service from scratch

1. Run service registration (`01-register-service-permissions.sh`) for the new service
2. Create `scripts/service-client-setup/` directory structure
3. Copy `register-as-client.sh` from an existing consumer (it's provider-agnostic)
4. Create `clients.d/<provider>.json` for each upstream provider
5. Create `07-register-consumer.sh` wrapper (or equivalent numbered script)
6. Follow "Adding a new provider" steps 3-7 above

## Key Files

| File | Purpose |
|------|---------|
| `clients.d/<provider>.json` | Config: what permissions the consumer needs |
| `register-as-client.sh` | Engine: 8-step registration (provider-agnostic) |
| `07-register-consumer.sh` | Wrapper: iterates providers, runs engine |
| `credentials/<provider>-client.json` | Output: API key + service account info |
| `app/<provider>_client.py` | Client: sends X-API-Key to upstream |

## Permission Design

- **Read-only by default** — consumers proxy data for display, not mutation
- **Always include `cross_tenant` / `cross_org`** — consumers serve multiple user orgs through one API key
- **Match provider's schema** — check provider's `permissions.json` for available permissions
- **Format**: `{provider}.{action}.{resource}` (e.g., `billing.read.accounts`)

## Security Rules

- **Never forward user JWT** to upstream — wrong audience, wrong permissions
- **Never leak upstream errors** to browser — log server-side, return generic message
- **Always inject org_id from validated JWT** — never from request params
- **Consumer API key stays server-side** — browser never sees it

## References

- **[Config schema and field reference](references/config-schema.md)** — complete `clients.d/*.json` format
- **[Client code patterns](references/client-patterns.md)** — `_headers()`, error handling, async HTTP
- **[Proxy route patterns](references/proxy-routes.md)** — route handlers, org_id injection, error masking
- **[Registration internals](references/registration-internals.md)** — what `register-as-client.sh` does step by step
- **[Mesh topology](references/mesh-topology.md)** — how services, orgs, audiences, and API keys relate
- **[Env and docker config](references/env-config.md)** — environment variables and docker-compose passthrough
- **[Troubleshooting](references/troubleshooting.md)** — common errors and fixes
