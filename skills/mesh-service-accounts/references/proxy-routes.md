# Proxy route pattern (FastAPI)

Your frontend calls **your** API; your API calls the provider with your key for the signed-in
customer's org. The pattern below uses `ab0t_auth` for the user check (Ally SOP 06) and the client
from `client-patterns.md`.

## The route

```python
import logging
from typing import Annotated

from fastapi import Depends, HTTPException
from ab0t_auth import AuthenticatedUser, require_permission

from app.auth import auth                                   # your AuthGuard (SOP 06)
from app.{provider}_client import {Provider}ServiceClient, {Provider}ServiceError

logger = logging.getLogger(__name__)
{provider}_client = {Provider}ServiceClient()

Reader = Annotated[AuthenticatedUser, Depends(require_permission(auth, "invoicer.read.invoices"))]


@app.get("/api/{provider}/{resource}")
async def get_{provider}_{resource}(user: Reader):
    try:
        return await {provider}_client.get_{resource}(user.org_id)     # org_id from the validated token
    except {Provider}ServiceError as e:
        logger.warning("{provider}_proxy_error status=%s org_id=%s", e.status_code, user.org_id)
        if e.status_code in (503, 504):
            raise HTTPException(status_code=503, detail="Service temporarily unavailable")
        if e.status_code == 404:
            raise HTTPException(status_code=404, detail="Not found")
        raise HTTPException(status_code=502, detail="Upstream request failed")
```

## The four rules

**1. `org_id` comes from the validated token, never from the request.**
```python
# right
return await client.get_balance(user.org_id)

# wrong: the caller chooses whose data to read
@app.get("/api/billing/{org_id}/balance")
async def get_balance(org_id: str):
    return await client.get_balance(org_id)
```

**2. Never send the provider's error text to the browser.** Log it server-side; answer with a short,
fixed message. Upstream details reveal internals and other customers' identifiers.

**3. Never forward the user's bearer token.** The client sends your service key; a user's token has
the wrong audience and the wrong permissions for the provider.

**4. Translate status codes at the boundary.**

| upstream | your response | why |
|---|---|---|
| unreachable / timeout | `503` "Service temporarily unavailable" | could not decide; the customer may retry |
| `401` / `403` on your key | `502` "Upstream request failed" | your key or tier is wrong: your problem, not the customer's (fix the tier, SOP 11) |
| `404` | `404` "Not found" | safe to pass through without detail |
| anything else | `502` "Upstream request failed" | safe catch-all |

## Naming

Your API owns its own paths (`/api/<provider>/<resource>`); the upstream path is whatever the
provider's API reference says, with the customer's `org_id` filled in by you. For billing, for
example, `GET /api/billing/balance` → `GET /billing/<org_id>/balance`. Check each provider's API
reference (its `/openapi.json`) for the real paths; do not guess.

## Pagination and files

Accept `limit` / `offset` (or the provider's cursor) from the frontend, validate them, and pass them
through. For a downloadable file (an invoice PDF), return the URL the provider gives you for that
customer's org and let the browser open it; never fetch another org's file because the browser asked.
