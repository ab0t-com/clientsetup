# Troubleshooting

Common errors and fixes for mesh service account registration and cross-service calls.

## Registration Errors

### "Provider credentials not found"

The provider service hasn't been registered yet.

**Fix**: Have the provider register its service (step 01):
```bash
authsetup --config-dir /path/to/<provider>/config run 01
```

### "Failed to login as provider admin"

The auth DB was wiped — the admin account no longer exists.

**Fix**: The cached admin credentials are stale (the account they point to is gone). Clear `~/.authmesh/<provider>/`, then re-register — the binary reconciles around the recovered identity:
```bash
authsetup --config-dir /path/to/<provider>/config run 01
```

### "Failed to create customer sub-org"

Provider admin token expired (JWTs last 15 minutes) or admin doesn't own the org.

**Fix**: Re-run the provider's `authsetup --config-dir ./config run 01`, then retry registration.

### "Failed to login service account with org context"

The service account wasn't added to the sub-org in step 5.

**Fix**: Check step 5 output. If invite failed, the provider admin may not have permission. Re-run the provider's `authsetup --config-dir ./config run 01`.

### "Failed to create API key"

The provider's permissions aren't registered in auth.

**Fix**: Re-run the provider's `authsetup --config-dir ./config run 01` (this registers the `{provider}.*` permissions), then retry.

## Runtime Errors

### 401 from upstream service

The API key is not being sent or is invalid.

**Check**:
```bash
# Validate key directly
curl -s -X POST https://auth.service.ab0t.com/auth/validate-api-key \
  -H "Content-Type: application/json" \
  -d '{"api_key": "ab0t_sk_live_..."}' | jq .valid
```

**Common causes**:
- `{PROVIDER}_SERVICE_API_KEY` not set in `.env`
- Env var not passed through in `docker-compose.yml`
- Key was created against a different auth instance (dev vs prod)
- Container not rebuilt after `.env` change

### 403 from upstream service

The API key doesn't have the required permissions.

**Check**:
```bash
curl -s -X POST https://auth.service.ab0t.com/auth/validate-api-key \
  -H "Content-Type: application/json" \
  -d '{"api_key": "ab0t_sk_live_..."}' | jq .permissions
```

**Common causes**:
- Missing `cross_tenant` / `cross_org` permission (needed for gateway pattern)
- Wrong permission name (e.g., `billing.read` vs `billing.read.accounts`)
- Permission not registered by provider (check provider's `permissions.json`)

**Fix**: Update `clients.d/<provider>.json` with correct permissions, then re-run `authsetup --config-dir ./config run 07`.

### 503 "Service unreachable"

The upstream service is not running or the URL is wrong.

**Check**:
```bash
# From host
curl -s http://localhost:{port}/health

# From inside container
docker exec <container> curl -s http://host.docker.internal:{port}/health
```

**Common causes**:
- Upstream service not started
- Wrong port in `{PROVIDER}_SERVICE_URL`
- Docker networking: container can't reach `host.docker.internal`

### 502 "Request failed" (generic)

The upstream returned an error (4xx/5xx). Check consumer service logs for the real error:

```bash
docker compose logs --tail 50 | grep "{provider}_proxy_error"
```

The log line contains the actual status and detail from upstream.

### TypeError: Logger._log() got unexpected keyword argument

Mixing structlog kwargs with stdlib logging.

```python
# structlog — kwargs OK
logger.warning("event", status=500, detail="err")

# stdlib — positional only
logger.warning("event status=%s detail=%s", 500, "err")
```

**Fix**: Match logger call style to whichever logger your service uses.

## After Auth DB Wipe

When the auth database is wiped (DynamoDB local restart, etc.), all orgs, accounts, and keys are gone.

Recovery order:
1. Clear stale credential dirs (`~/.authmesh/<service>/`)
2. Re-register provider services (`authsetup --config-dir ./config run 01`)
3. Re-register your service (`authsetup --config-dir ./config run 01`)
4. Re-register consumer accounts (`authsetup --config-dir ./config run 07`)
5. Update `.env` with new API keys
6. Rebuild containers

## Debugging Checklist

```
[ ] Auth service healthy?
    curl https://auth.service.ab0t.com/health

[ ] API key valid?
    POST /auth/validate-api-key { api_key: "..." } → valid: true

[ ] Key has right permissions?
    Check .permissions in validation response

[ ] Key has cross_tenant / cross_org?
    Required for gateway pattern

[ ] Env var set in .env?
    grep {PROVIDER}_SERVICE_API_KEY .env

[ ] Env var passed through in docker-compose.yml?
    grep {PROVIDER}_SERVICE docker-compose.yml

[ ] Container rebuilt after .env change?
    docker compose up -d --build

[ ] Upstream service running?
    curl http://localhost:{port}/health

[ ] URL uses host.docker.internal (not localhost) from container?
    Container can't reach host's localhost
```
