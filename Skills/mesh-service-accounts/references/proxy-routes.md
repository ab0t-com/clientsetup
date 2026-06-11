# Proxy Route Patterns

How to wire up FastAPI routes that proxy requests to upstream mesh services.

## Standard Pattern

```python
from fastapi import Depends, HTTPException
from app.auth import require_auth, AuthenticatedUser
from app.{provider}_client import {Provider}ServiceClient, {Provider}ServiceError
import logging

logger = logging.getLogger(__name__)
{provider}_client = {Provider}ServiceClient()


@app.get("/api/{provider}/{resource}")
async def get_{provider}_{resource}(
    user: AuthenticatedUser = Depends(require_auth)
):
    try:
        return await {provider}_client.get_{resource}(user.org_id)
    except {Provider}ServiceError as e:
        logger.warning(
            "{provider}_proxy_error status=%s detail=%s org_id=%s",
            e.status_code, e.detail, user.org_id
        )
        if e.status_code == 503:
            raise HTTPException(status_code=503, detail="{Provider} service unavailable")
        elif e.status_code == 504:
            raise HTTPException(status_code=504, detail="{Provider} service timeout")
        else:
            raise HTTPException(status_code=502, detail="{Provider} request failed")
```

## Security Rules (Mandatory)

### 1. org_id comes from JWT, never from request

```python
# CORRECT — org_id from validated JWT claims
return await client.get_balance(user.org_id)

# WRONG — org_id from URL parameter (spoofable)
@app.get("/api/billing/{org_id}/balance")
async def get_balance(org_id: str):
    return await client.get_balance(org_id)  # attacker controls org_id
```

### 2. Never leak upstream error details to browser

```python
# CORRECT — generic message, real error logged server-side
except {Provider}ServiceError as e:
    logger.warning("proxy_error status=%s detail=%s", e.status_code, e.detail)
    raise HTTPException(status_code=502, detail="{Provider} request failed")

# WRONG — upstream internals sent to browser
except {Provider}ServiceError as e:
    raise HTTPException(status_code=e.status_code, detail=e.detail)
```

### 3. Never forward user JWT to upstream

```python
# CORRECT — client uses its own API key (set in __init__ from env)
return await client.get_balance(user.org_id)

# WRONG — user's JWT has wrong audience, wrong permissions
token = request.headers.get("Authorization", "").replace("Bearer ", "")
return await client.get_balance(user.org_id, token=token)
```

### 4. Translate status codes at the boundary

Map upstream errors to appropriate proxy errors:

| Upstream | Proxy Response | Why |
|----------|---------------|-----|
| 503 (unreachable) | 503 "{Provider} service unavailable" | Upstream is down |
| 504 (timeout) | 504 "{Provider} service timeout" | Upstream too slow |
| 401/403 (auth) | 502 "{Provider} request failed" | Consumer key issue — internal, not user's fault |
| 404 (not found) | 404 "Resource not found" | Can pass through (no internal detail) |
| Everything else | 502 "{Provider} request failed" | Safe catch-all |

## Route Naming Convention

```
Frontend URL:    /api/{provider}/{resource}
Upstream URL:    /{provider}/{org_id}/{resource}
```

The consumer service owns the `/api/` prefix. The upstream service uses org_id in the path.

Examples:

| Consumer Route | Upstream Route |
|---------------|---------------|
| `GET /api/billing/balance` | `GET /billing/{org_id}/balance` |
| `GET /api/billing/transactions` | `GET /billing/{org_id}/transactions` |
| `GET /api/payments/subscriptions` | `GET /subscriptions/{org_id}` |
| `GET /api/payments/invoices` | `GET /invoices/{org_id}` |

## Pagination Pass-through

For paginated upstream endpoints, accept pagination params from the frontend and forward them:

```python
@app.get("/api/{provider}/{resource}")
async def get_{resource}(
    limit: int = 20,
    offset: int = 0,
    user: AuthenticatedUser = Depends(require_auth)
):
    try:
        return await {provider}_client.get_{resource}(
            user.org_id, limit=limit, offset=offset
        )
    except {Provider}ServiceError as e:
        # ... standard error handling
```

## File Redirects (e.g., Invoice PDFs)

When the upstream returns a redirect to a file (S3 pre-signed URL):

```python
@app.get("/api/payments/invoices/{invoice_id}/pdf")
async def get_invoice_pdf(
    invoice_id: str,
    user: AuthenticatedUser = Depends(require_auth)
):
    try:
        url = await payment_client.get_invoice_pdf_url(user.org_id, invoice_id)
        return {"pdf_url": url}
    except PaymentServiceError as e:
        # ... standard error handling
```

The client follows the redirect chain and returns the final URL. The frontend opens it in a new tab.
