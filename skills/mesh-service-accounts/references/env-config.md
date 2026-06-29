# Env and Docker Config

Environment variables and docker-compose passthrough for mesh service accounts.

## Consumer Side (the service making cross-service calls)

### .env

For each upstream provider, add two variables:

```env
# {Provider} Service ({description} — port {port})
{PROVIDER}_SERVICE_URL=http://host.docker.internal:{port}
{PROVIDER}_SERVICE_API_KEY=ab0t_sk_live_...
```

Concrete example (sandbox-platform consuming billing + payment):

```env
# Billing Service (usage tracking, balance, transactions — port 8002)
BILLING_SERVICE_URL=http://host.docker.internal:8002
BILLING_SERVICE_API_KEY=ab0t_sk_live_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

# Payment Service (subscriptions, invoices, Stripe — port 8005)
PAYMENT_SERVICE_URL=http://host.docker.internal:8005
PAYMENT_SERVICE_API_KEY=ab0t_sk_live_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

### docker-compose.yml

Pass each variable through to the container:

```yaml
services:
  my-service:
    environment:
      # Upstream providers
      - {PROVIDER}_SERVICE_URL=${{PROVIDER}_SERVICE_URL:-https://{provider}.service.ab0t.com}
      - {PROVIDER}_SERVICE_API_KEY=${{PROVIDER}_SERVICE_API_KEY:-}
```

### URL patterns

| Environment | URL Pattern | Notes |
|-------------|-------------|-------|
| Docker → host service | `http://host.docker.internal:{port}` | Container reaching host |
| Host → local service | `http://localhost:{port}` | Direct local access |
| Production | `https://{provider}.service.ab0t.com` | DNS-routed |

## Provider Side (the service receiving cross-service calls)

### .env

Every service that can receive API key-authenticated calls needs:

```env
# Auth mesh — audience enforcement
AB0T_AUTH_AUTH_URL=https://auth.service.ab0t.com
AB0T_AUTH_AUDIENCE={service-specific-audience}
AB0T_AUTH_AUDIENCE_SKIP=false

# Auth mesh — API key support
AB0T_AUTH_ENABLE_API_KEY_AUTH=true
AB0T_AUTH_API_KEY_HEADER=X-API-Key
```

### docker-compose.yml

```yaml
environment:
  - AB0T_AUTH_URL=${AB0T_AUTH_URL:-https://auth.service.ab0t.com}
  - AB0T_AUTH_AUDIENCE=${AB0T_AUTH_AUDIENCE}
  - AB0T_AUTH_AUDIENCE_SKIP=${AB0T_AUTH_AUDIENCE_SKIP:-false}
  - AB0T_AUTH_ENABLE_API_KEY_AUTH=${AB0T_AUTH_ENABLE_API_KEY_AUTH:-true}
  - AB0T_AUTH_API_KEY_HEADER=${AB0T_AUTH_API_KEY_HEADER:-X-API-Key}
```

## Getting API Keys from Registration Output

After running `07-register-consumer.sh`, extract keys from the credential files:

```bash
# From the consumer credential file
jq -r '.api_key.key' credentials/billing-consumer.json

# Or from the raw client output
jq -r '.api_key.key' scripts/service-client-setup/credentials/billing-client.json
```

## Key Rotation

To rotate a consumer API key:

1. Re-run `07-register-consumer.sh <provider>` — creates a new key (old key stays valid)
2. Update `.env` with the new key
3. Rebuild: `docker compose up -d --build`
4. Verify the new key works
5. (Optional) Delete the old key from auth dashboard

Old keys remain valid until explicitly revoked. This allows zero-downtime rotation.
