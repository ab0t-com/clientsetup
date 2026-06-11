# OAuth and Hosted Login

## OAuth Client Config (config/oauth-client.json)

```json
{
  "client_name": "Sandbox Platform Frontend",
  "redirect_uris": [
    "https://sandbox.dev.ab0t.com/auth/callback",
    "http://localhost:3000/auth/callback"
  ],
  "grant_types": ["authorization_code", "refresh_token"],
  "response_types": ["code"],
  "token_endpoint_auth_method": "none",
  "scope": "openid profile email"
}
```

### Fields

| Field | Required | Description |
|-------|----------|-------------|
| `client_name` | Yes | Display name shown in consent screens |
| `redirect_uris` | Yes | Exact-match callback URLs. Include both prod and localhost for dev |
| `grant_types` | Yes | Use `["authorization_code", "refresh_token"]` for web apps |
| `response_types` | Yes | Use `["code"]` for authorization code flow |
| `token_endpoint_auth_method` | Yes | `"none"` for public clients (SPA/mobile) — uses PKCE instead of client_secret |
| `scope` | Yes | Space-separated OAuth scopes. Standard: `"openid profile email"` |

### Key Rules

- **Public clients** (SPA, mobile) must use `token_endpoint_auth_method: "none"` + PKCE
- **Redirect URIs** must match exactly during OAuth flow (no wildcards)
- **Include localhost** in redirect_uris for local development
- Step 02 registers via RFC 7591 (`POST /auth/oauth/register`)
- Output includes `registration_access_token` for RFC 7592 updates

## Hosted Login Config (config/hosted-login.json)

```json
{
  "branding": {
    "primary_color": "#111111",
    "background_color": "#FAFAFA",
    "page_title": "Sandbox Platform - Sign In",
    "hide_powered_by": false,
    "login_template": "default"
  },
  "content": {
    "welcome_message": "Sign in to Sandbox Platform",
    "signup_message": "Create your account",
    "footer_message": "Sandbox Platform by ab0t"
  },
  "auth_methods": {
    "email_password": true,
    "signup_enabled": true,
    "invitation_only": false
  },
  "registration": {
    "default_role": "member",
    "require_email_verification": false,
    "collect_name": true
  },
  "security": {
    "post_logout_redirect_uri": "https://sandbox.dev.ab0t.com",
    "remember_me_enabled": true,
    "accept_invite_url": "https://sandbox.dev.ab0t.com/welcome",
    "accept_invite_error_url": "https://sandbox.dev.ab0t.com/invite-error",
    "accept_invite_allowed_origins": ["https://sandbox.dev.ab0t.com"]
  }
}
```

### Fields

| Section | Field | Description |
|---------|-------|-------------|
| `branding.primary_color` | Hex color for buttons, links |
| `branding.page_title` | Browser tab title |
| `branding.login_template` | `"default"`, `"minimal"`, or `"corporate"` |
| `content.welcome_message` | Main heading on login page |
| `content.signup_message` | Heading on registration form |
| `auth_methods.signup_enabled` | Allow self-registration |
| `auth_methods.invitation_only` | Override — if true, signup_enabled is ignored |
| `registration.default_role` | Role for new users. Step 04 overrides to `"member"` |
| `registration.default_team` | Team ID for auto-join. Step 04 injects this |
| `security.post_logout_redirect_uri` | Where to send users after logout |
| `security.accept_invite_url` | Where the auth service redirects valid invitation clicks. Auth appends `?code=<…>`. Optional — leave unset to use the bundled fallback. |
| `security.accept_invite_error_url` | Where the auth service redirects used / expired / unknown invitations. Auth appends `?reason=used\|expired\|not_found\|invalid`. Optional. |
| `security.accept_invite_allowed_origins` | Allowlist of origins (`scheme://host[:port]`, no path) the two URLs above may target. Smart-defaulted by step 03 from `oauth-client.json` redirect_uris if you leave it empty. |

### Important

- Step 03 applies config via `PUT /organizations/{org_id}/login-config` (full replace, not merge)
- Step 04 **injects** `registration.default_role = "member"` and `registration.default_team = {team_id}` into this config
- The hosted login page is public at: `{AUTH_SERVICE_URL}/login/{org_slug}`

### Invitation-link landing (`security.accept_invite_*`)

When you POST `/organizations/{id}/invite`, the email link points at the auth service's canonical `/accept-invite?code=...` endpoint. The auth service then 302-redirects the invitee to **the customer's** app — to whichever URL is configured here.

Why this design:
- **Email links survive app-domain rebrands.** Click target is `auth.service.ab0t.com`; only the redirect destination changes when you update `accept_invite_url`.
- **Failed invitations get a useful page.** Used / expired / unknown codes redirect to `accept_invite_error_url?reason=...` so the customer's app can render a friendly message instead of "invalid token".

Smart-default behavior (step 03):
- `accept_invite_allowed_origins` — IF empty/missing in user config, derived from `oauth-client.json` redirect_uris. Those origins are already trusted for OAuth callbacks; reusing them mirrors the existing trust boundary.
- `accept_invite_url` / `accept_invite_error_url` — NEVER smart-defaulted. Customer-specific UX decisions; a wrong default would silently misroute invitees. Leave unset to use the bundled fallback page.

Pre-flight check (step 03 + `validate-config.sh`): warns when a configured URL's origin isn't in the allowlist (auth would reject the PUT with HTTP 400; warning catches it before the network round-trip).

Allowlist rules (mirrors OAuth `redirect_uris`):
- Each entry is `scheme://host[:port]` — no path, no trailing slash.
- `https://app.example.com` and `http://app.example.com` are different origins (scheme is part of the comparison).
- Auth service rejects writes where the URL origin is not in the allowlist.

Auth-service code: `appv2/modules/hosted_login/api/accept_invite.py` (endpoint), `appv2/services/organization/invitation_service.py:lookup_invitation_by_code` (read-only state lookup). Ticket: `tickets/20260508_invitation_list_returns_empty_and_no_email/PART3`.

## Hosted Login URLs

| Endpoint | Purpose |
|----------|---------|
| `GET /login/{org_slug}` | Public login page (HTML) |
| `GET /organizations/{org_slug}/login-config/public` | Public config (JSON, for BYOUI) |
| `GET /organizations/{org_slug}/auth/providers` | Available auth methods |
| `POST /organizations/{org_slug}/auth/login` | Org-scoped login |
| `POST /organizations/{org_slug}/auth/register` | Org-scoped registration |
| `POST /organizations/{org_slug}/auth/authorize` | OAuth authorization (PKCE) |
| `GET /accept-invite?code=...` | Public invitation-link landing — 302-redirects to the org's `accept_invite_url` (valid) or `accept_invite_error_url?reason=...` (used/expired/unknown). Falls back to a bundled HTML page when the org has no PART3 config. Sets `Referrer-Policy: no-referrer`. Rate-limited per IP. |

## Two Integration Patterns

### SDK-Based (recommended for SPAs)

Frontend uses `@authmesh/sdk` — handles OAuth 2.1 PKCE flow automatically:

```javascript
import { AuthMeshClient } from '@authmesh/sdk';

const auth = new AuthMeshClient({
  domain: 'https://auth.service.ab0t.com',
  org: 'sandbox-platform-users',     // end-users org slug
  clientId: 'client_UxYgGTDmyVgBwnyzTDhI1Q',
  redirectUri: window.location.origin + '/auth/callback',
  scope: 'openid profile email',
});
```

### BYOUI (custom login form)

Frontend calls org-scoped API directly — no redirects, no SDK:

```javascript
const response = await fetch(
  `https://auth.service.ab0t.com/organizations/${orgSlug}/auth/login`,
  {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password })
  }
);
const { access_token, refresh_token } = await response.json();
```

### Which Org Slug?

- **Service org** (`sandbox-platform`): for admin login, API key management
- **End-users org** (`sandbox-platform-users`): for user registration and login. This is what the frontend uses
