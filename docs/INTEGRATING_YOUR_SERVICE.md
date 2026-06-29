# Wire your service to verify auth

`authsetup` got you set up: your org, an admin login, an end-users hosted-login
page, and an OAuth client your frontend signs people in with. It stops there.
The next job is yours: **on every request, your service must verify the bearer
token (a signed-in user) or the API key (another service) it now receives, and
read the caller's `org_id` + `permissions` from the result.** You do that by
calling two endpoints on the auth service — you never parse or trust a token
yourself.

> Live source of truth for these endpoints is the auth service's
> `/openapi.json` (e.g. `https://auth.service.ab0t.com/openapi.json`). The
> shapes below are accurate at time of writing; the spec is authoritative.

---

## 1. Verify a user JWT

Your frontend sends `Authorization: Bearer <jwt>`. Validate it and pin the
audience to your service:

```bash
curl -s https://auth.service.ab0t.com/auth/validate-token \
  -H 'Content-Type: application/json' \
  -d '{
        "token": "'"$JWT"'",
        "expected_audience": "myservice"
      }'
# → {"valid": true, "user_id": "...", "org_id": "...", "permissions": ["myservice.read.items", ...]}
```

FastAPI dependency sketch:

```python
import httpx
from fastapi import Depends, Header, HTTPException
from fastapi.security import HTTPBearer

AUTH_URL = "https://auth.service.ab0t.com"
MY_AUDIENCE = "myservice"          # == your service.id — see §4
bearer = HTTPBearer()

async def current_user(creds = Depends(bearer)) -> dict:
    async with httpx.AsyncClient(timeout=5) as c:
        r = await c.post(f"{AUTH_URL}/auth/validate-token", json={
            "token": creds.credentials,
            "expected_audience": MY_AUDIENCE,
        })
    data = r.json()
    if not data.get("valid"):
        raise HTTPException(status_code=401, detail="invalid token")
    return data   # {"user_id", "org_id", "permissions": [...]}

def require(permission: str):
    async def dep(user: dict = Depends(current_user)) -> dict:
        perms = user.get("permissions", [])
        if not _granted(permission, perms):
            raise HTTPException(status_code=403, detail="forbidden")
        return user
    return dep

def _granted(needed: str, held: list[str]) -> bool:
    # permissions are "{service}.{action}.{resource}"; honor wildcards
    svc = needed.split(".")[0]
    return needed in held or f"{svc}.*" in held or \
           ".".join(needed.split(".")[:2]) in held

@app.get("/items")
async def list_items(user = Depends(require("myservice.read.items"))):
    ...
```

> Permissions are `{service}.{action}.{resource}` (also `{service}.{action}` and
> the `{service}.*` wildcard). Authorize off the returned `permissions`, or ask
> the auth service directly: `POST /permissions/check {user_id, permission,
> org_id}`. Newly registered permissions propagate within ~5 min (registry
> cache) or immediately on the user's next fresh login.

---

## 2. Verify a service-to-service API key

Another service (or a backend job) calls you with `X-API-Key: <key>`. Validate
it the same way:

```bash
curl -s https://auth.service.ab0t.com/auth/validate-api-key \
  -H 'Content-Type: application/json' \
  -d '{
        "api_key": "'"$API_KEY"'",
        "required_permissions": ["myservice.write.items"],
        "expected_audience": "myservice"
      }'
# → {"valid": true, "user_id": "...", "org_id": "...", "permissions": [...]}
```

`required_permissions` and `expected_audience` are optional but recommended —
let the auth service do the check so you fail closed. The response shape matches
`validate-token`, so the same `require(...)` logic applies.

---

## 3. The audience claim — decide it before you launch

The token's `aud` resolves to your org's `service_audience`, falling back to the
org slug. For a service set up by this kit, **your org's slug == your
`service.id`**, so:

```
expected_audience == your service.id
```

That value is **immutable after the org is created.** You cannot rename it
later. Pick `service.id` deliberately at first `run` — it is the audience every
caller will need to target forever. Always pass `expected_audience` on
validation so a token minted for another service can't be replayed against
yours.

---

## 4. Where your credentials live

After setup, your credentials are under `~/.authmesh/<service>/` (dev and prod
are isolated by a `-dev` filename suffix; promote by re-running config against
prod, never by copying files):

| File | What it is | Who uses it |
|---|---|---|
| `end-users-oauth-client.json` (`…-dev.json`) | the **frontend** `client_id` + hosted-login URL for signing users in | your web frontend |
| `<service>.json` | the **service-internal API key** for server-to-server calls you make outbound | your backend |

The `client_id` is public (it ships to the browser). The API key in
`<service>.json` is a secret — keep it server-side, inject via env, never bundle
it into frontend code.

---

## 5. Going further

- **For the full FastAPI pattern** (middleware, caching validations, scoped
  dependencies, error handling) load the `ab0t-auth-fastapi` skill.
- **The live API contract** is always the auth service's `/openapi.json` —
  check it before coding against any endpoint here.
