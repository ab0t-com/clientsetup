# Client code pattern (Python, async)

One small client per upstream provider. It sends **your service's** key, never a user's token, and
turns every upstream failure into one typed error your routes can map to a safe response.

## The client

```python
"""
Client for the {Provider} service.

Gateway pattern: your backend calls {provider} for authenticated users. The browser never talks to
{provider} directly, and org_id always comes from the caller's validated token.
"""

import os
from typing import Any, Dict

import httpx
import structlog

logger = structlog.get_logger()


class {Provider}ServiceError(Exception):
    """An upstream failure, already logged; map it to a generic response in your route."""
    def __init__(self, status_code: int, detail: str):
        self.status_code = status_code
        self.detail = detail
        super().__init__(f"{Provider} service error ({status_code})")


class {Provider}ServiceClient:
    def __init__(self) -> None:
        self.base_url = os.environ["{PROVIDER}_SERVICE_URL"].rstrip("/")   # no silent default: fail at start-up
        self.api_key = os.environ["{PROVIDER}_SERVICE_API_KEY"]            # from your secrets manager
        self.client = httpx.AsyncClient(timeout=15.0)

    def _headers(self) -> Dict[str, str]:
        headers = {"Content-Type": "application/json"}
        if self.api_key.startswith("ab0t_sk_"):
            headers["X-API-Key"] = self.api_key          # mesh service keys
        else:
            headers["Authorization"] = f"Bearer {self.api_key}"   # a token minted for this provider (e.g. client credentials)
        return headers

    @staticmethod
    def _extract_detail(response: httpx.Response) -> str:
        """For your server log only — never return this to the browser."""
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

    async def _request(self, method: str, path: str, **kwargs) -> Any:
        url = f"{self.base_url}{path}"
        try:
            response = await self.client.request(method, url, headers=self._headers(), **kwargs)
        except httpx.ConnectError as e:
            logger.warning("{provider}_unreachable", url=url, error=str(e))
            raise {Provider}ServiceError(503, "unreachable")
        except httpx.TimeoutException:
            logger.warning("{provider}_timeout", url=url)
            raise {Provider}ServiceError(504, "timeout")

        if response.status_code >= 400:
            detail = self._extract_detail(response)
            logger.warning("{provider}_error", url=url, status=response.status_code, detail=detail)
            raise {Provider}ServiceError(response.status_code, detail)
        return response.json()

    async def close(self) -> None:
        await self.client.aclose()

    # --- one method per upstream call you actually use ---

    async def get_{resource}(self, org_id: str) -> Dict[str, Any]:
        return await self._request("GET", f"/{provider}/{org_id}/{resource}")
```

Settings (Pydantic `BaseSettings` or equivalent):
```python
{PROVIDER}_SERVICE_URL: str
{PROVIDER}_SERVICE_API_KEY: str
```
Fill them from the two lines `authsetup --env <env> connect <provider> --as <you>` prints; the key
value comes from `~/.authmesh/<you>/<provider>-consumer.<env>.json` (`.api_key.key`) via your secrets
manager, never pasted into code or chat.

## Why it looks like this

- **No user token parameter.** A user's token is minted for *your* audience; the provider rejects it,
  and even if it did not, it would carry the user's permissions instead of your tier's. Your key is
  the identity.
- **Key format by prefix.** Mesh service keys start `ab0t_sk_` and go in `X-API-Key`; anything else
  you hold for a provider is a bearer token.
- **No default URL.** A missing URL should stop the service at start-up, not quietly send a dev key to
  production.
- **15-second timeout.** Backend-to-backend calls should be fast; fail fast and let the caller retry.
- **`_extract_detail` is for logs.** Providers answer in different shapes (`detail`, `message`,
  `error`); log it, never forward it (see `proxy-routes.md`).

## Logger choice

structlog takes keyword arguments; stdlib `logging` does not. Do not mix them:
```python
import logging
logger = logging.getLogger(__name__)
logger.warning("provider_error url=%s status=%s", url, status)   # stdlib: positional only
```
Passing keywords to a stdlib logger fails with `TypeError: Logger._log() got an unexpected keyword argument`.
