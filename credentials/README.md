# Credentials

| File | Scope | Notes |
|------|-------|-------|
| `sandbox-platform.json` | Service org — backend API key + admin credentials | Server-to-server auth |
| `oauth-client.json` | Service org — OAuth client registration | Registered under service org, NOT used by end-users |
| `end-users-org.json` | End-users org — org config + default team + OAuth client ID | Frontend `auth-init.js` uses `oauth_client_id` from this file |
| `hosted-login.json` | End-users org — hosted login config snapshot | Applied branding/registration settings |
| `*-dev.json` | Dev environment equivalents | localhost:8001 targets |

COMPLIANCE: [A-002] Service and end-user OAuth clients are separate registrations in separate orgs.
