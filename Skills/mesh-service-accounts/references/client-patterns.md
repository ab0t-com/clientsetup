# Client Code Patterns

How to write the Python client that calls an upstream mesh service using the consumer API key.

## Canonical Implementation

Based on `billing_client.py` and `payment_client.py` from sandbox-platform.

```python
"""
Client for the {Provider} Service (port {port}).

Gateway pattern: backend proxies {provider} requests on behalf of
authenticated users. The frontend never talks to {provider} directly.
Backend injects org_id from the validated JWT — cannot be spoofed.
"""

import httpx
import os
from typing import Dict, Any, Optional
import structlog

logger = structlog.get_logger()


class {Provider}ServiceError(Exception):
    """Structured error from {provider} service requests."""
    def __init__(self, status_code: int, detail: str):
        self.status_code = status_code
        self.detail = detail
        super().__init__(f"{Provider} service error ({status_code}): {detail}")


class {Provider}ServiceClient:
    """Async HTTP client for the {provider} service."""

    def __init__(self):
        self.base_url = os.getenv(
            "{PROVIDER}_SERVICE_URL",
            "https://{provider}.service.ab0t.com"
        ).rstrip("/")
        self.api_key = os.getenv("{PROVIDER}_SERVICE_API_KEY", "")
        self.client = httpx.AsyncClient(timeout=15.0)

    def _headers(self, forwarded_token: Optional[str] = None) -> Dict[str, str]:
        """Build request headers.

        Priority: forwarded token (if provided) > static API key > no auth.
        API key format auto-detected:
          - Contains '.' → JWT → Authorization: Bearer
          - Otherwise → opaque → X-API-Key header
        """
        headers = {"Content-Type": "application/json"}
        if forwarded_token:
            headers["Authorization"] = f"Bearer {forwarded_token}"
        elif self.api_key:
            if "." in self.api_key:
                headers["Authorization"] = f"Bearer {self.api_key}"
            else:
                headers["X-API-Key"] = self.api_key
        return headers

    @staticmethod
    def _extract_detail(response: httpx.Response) -> str:
        """Extract error detail from upstream response."""
        try:
            body = response.json()
            if isinstance(body, dict):
                detail = body.get("detail") or body.get("message") or body.get("error")
                if isinstance(detail, str) and detail.strip():
                    return detail.strip()
        except Exception:
            pass
        text = (response.text or "").strip()
        return text[:500] if text else f"HTTP {response.status_code}"

    async def _request(self, method: str, path: str,
                       token: Optional[str] = None, **kwargs) -> Any:
        """Make a request to the {provider} service."""
        url = f"{self.base_url}{path}"
        try:
            response = await self.client.request(
                method, url, headers=self._headers(token), **kwargs
            )
        except httpx.ConnectError as e:
            logger.warning("{provider}_service_unreachable", url=url, error=str(e))
            raise {Provider}ServiceError(503, "{Provider} service unreachable")
        except httpx.TimeoutException:
            logger.warning("{provider}_service_timeout", url=url)
            raise {Provider}ServiceError(504, "{Provider} service timeout")

        if response.status_code >= 400:
            detail = self._extract_detail(response)
            logger.warning("{provider}_service_error",
                           url=url, status=response.status_code, detail=detail)
            raise {Provider}ServiceError(response.status_code, detail)

        return response.json()

    async def close(self):
        await self.client.aclose()

    # --- Resource methods ---

    async def get_{resource}(self, org_id: str,
                             token: Optional[str] = None) -> Dict[str, Any]:
        """Get {resource} for the given org."""
        return await self._request("GET", f"/{provider}/{org_id}/{resource}",
                                   token=token)
```

## Key Design Decisions

### Why `_headers()` auto-detects key format

API keys in the mesh come in two flavors:
- **Opaque keys** (`ab0t_sk_live_...`) — sent as `X-API-Key` header. The callee validates via `POST /auth/validate-api-key`
- **JWT keys** (contains `.`) — sent as `Authorization: Bearer`. The callee validates via JWKS

The `"." in self.api_key` check handles both formats transparently. Currently all consumer keys are opaque (`ab0t_sk_live_*`).

### Why `forwarded_token` parameter exists but is rarely used

The `token` parameter on each method allows forwarding a user's JWT for cases where the upstream service **does** accept the consumer's audience. In the standard mesh pattern, this is not used — the static API key handles auth. The parameter exists for backward compatibility and edge cases.

### Why 15-second timeout

Backend-to-backend calls should complete quickly. If the upstream is taking >15s, something is wrong (deadlock, slow query, etc.). Fail fast so the user gets a response.

### Why `_extract_detail()` parses multiple formats

Different services return errors differently:
- `{"detail": "Not found"}` — FastAPI default
- `{"message": "Rate limited"}` — some services
- `{"error": "Invalid request"}` — others

The extractor tries each format and falls back to raw text.

## Logger Choice

If your service uses **structlog**:
```python
import structlog
logger = structlog.get_logger()
logger.warning("event_name", url=url, status=status)  # kwargs OK
```

If your service uses **stdlib logging**:
```python
import logging
logger = logging.getLogger(__name__)
logger.warning("event_name url=%s status=%s", url, status)  # positional only
```

Do NOT mix — structlog kwargs on a stdlib logger causes `TypeError: Logger._log() got an unexpected keyword argument`.

## Adding Settings

In `app/config.py` (Pydantic BaseSettings or equivalent):

```python
{PROVIDER}_SERVICE_URL: str = ""
{PROVIDER}_SERVICE_API_KEY: str = ""
```
