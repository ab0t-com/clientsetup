# Step Internals

What each numbered step does, the auth API endpoints it calls, and non-obvious behavior. Each step is a phase of the `authsetup` binary — run them all with `authsetup --config-dir ./config run`, or a single step with `authsetup --config-dir ./config run 0X`. (These steps were formerly individual bash scripts; the API flows below are unchanged.)

## Step 01 — `authsetup --config-dir ./config run 01` (register-service-permissions)

**Purpose:** Create service org, register permission schema, create admin account and API key.

**Reads:** `config/permissions.json`
**Outputs:** `~/.authmesh/<service-id>/{service_id}.json` (or `{service_id}-dev.json` for local auth)

**API Flow:**

```
1. POST /auth/register          → create admin account (or login if exists)
2. POST /auth/login             → get access token (fallback)
3. POST /organizations/         → create service org with service_audience field
4. POST /auth/login (org_id)    → get org-scoped token
5. POST /permissions/registry/register → register permission schema
6. POST /permissions/grant      → grant implied permissions to admin
7. POST /api-keys/              → create org-wide API key
```

**Gotchas:**
- Includes `service_audience` field in org creation payload — used by auth for RFC 9068 JWT audience resolution
- Admin password is auto-generated if not in existing credentials. Override via `ADMIN_PASSWORD` env var
- If org creation fails, falls back to searching `GET /users/me/organizations` by slug
- Validates cached org_id still exists on server before reusing (`GET /organizations/{org_id}`)
- `implies` permissions are granted to admin via `POST /permissions/grant` for each implied permission

## Step 02 — `authsetup --config-dir ./config run 02` (register-oauth-client)

**Purpose:** Register OAuth 2.1 public client for frontend PKCE flow.

**Reads:** `config/oauth-client.json`, `~/.authmesh/<service-id>/{service_id}.json`
**Outputs:** `~/.authmesh/<service-id>/oauth-client.json` (or `oauth-client-dev.json` for local auth)

**API Flow:**

```
1. POST /auth/login                → authenticate as service admin
2. POST /auth/oauth/register       → RFC 7591 client registration
   OR
   PUT {registration_client_uri}   → RFC 7592 client update (if exists)
```

**Gotchas:**
- Reconciles: if the client already exists it is updated in place (RFC 7592 PUT), not recreated — `run` is re-runnable
- Update requires `registration_access_token` and `registration_client_uri` from previous registration
- New registration creates a separate client (old one stays valid)
- Output includes `registration_access_token` — save this for future updates

## Step 03 — `authsetup --config-dir ./config run 03` (setup-hosted-login)

**Purpose:** Configure login page branding, auth methods, and registration settings.

**Reads:** `config/hosted-login.json`, `~/.authmesh/<service-id>/{service_id}.json`, `config/oauth-client.json` (for smart default)
**Outputs:** `~/.authmesh/<service-id>/hosted-login.json` (or `hosted-login-dev.json` for local auth)

**API Flow:**

```
1. POST /auth/login                              → authenticate as admin
2. (local) Smart-default + pre-flight checks     → see below
3. PUT /organizations/{org_id}/login-config       → apply full config (replace)
4. GET /login/{org_slug}                          → verify page loads (200)
5. GET /organizations/{org_slug}/login-config/public → verify public config
6. GET /organizations/{org_slug}/auth/providers   → verify auth methods
```

**Smart default (PART3 — invitation-link landing):**
If `security.accept_invite_allowed_origins` is empty/missing, the step derives it from `oauth-client.json` redirect_uris (extracts unique `scheme://host` origins). Those origins are already trusted for OAuth callbacks; reusing them mirrors the existing trust boundary. The step prints which origins were filled. `accept_invite_url` and `accept_invite_error_url` are NEVER smart-defaulted — those are customer-specific UX decisions.

**Pre-flight check:** When `accept_invite_url` / `accept_invite_error_url` is configured but its origin isn't in the (resolved) allowlist, the step prints a warning pointing at the right config line. The auth service would otherwise reject the PUT with HTTP 400 — the warning catches it before the network round-trip.

**Gotchas:**
- `PUT` **deep-merges** onto the stored login config (fields you send overwrite; nested objects merge; omitted fields are preserved). Step 03 sends the whole `hosted-login.json`, so it is authoritative for the fields it manages, but the endpoint itself does not drop unrelated keys.
- Verification HTTP codes are stored in output file for debugging
- Login page is immediately available after PUT
- The smart-default origin extraction parses each redirect_uri into a `scheme://host` origin. IPv6 hosts inside brackets are handled cleanly; entries that don't match (no scheme, malformed) are silently skipped rather than aborting the whole step.

## Step 04 — `authsetup --config-dir ./config run 04` (setup-default-team)

**Purpose:** Create end-users child org with default team for team-based permission inheritance. This is the most complex step.

**Reads:** `config/permissions.json`, `config/hosted-login.json`, `~/.authmesh/<service-id>/{service_id}.json`
**Outputs:** `~/.authmesh/<service-id>/end-users-org.json` (or `end-users-org-dev.json` for local auth)

**API Flow:**

```
1.  POST /auth/login                              → authenticate as admin
2.  GET /users/me/organizations                    → check for existing end-users org
3.  POST /organizations/                           → create end-users org (parent_id = service org)
4.  POST /auth/login (end-users org_id)            → get org context token
5.  GET /organizations/{eu_id}/teams               → check for existing default team
6.  POST /organizations/{eu_id}/teams              → create default team with default_grant permissions
7.  POST /permissions/registry/register            → register permission schema on end-users org
8.  PUT /organizations/{eu_id}/login-config        → inject default_team + default_role into config
9.  GET /login/{eu_slug}                           → verify hosted login page
10. GET /organizations/{eu_id}/clients             → check for OAuth client
11. POST /auth/oauth/register                      → register OAuth client on end-users org
```

**Gotchas:**
- Setting `parent_id` in org creation auto-writes Zanzibar relation: `organization:{child}#parent@org:{parent}`
- Default team permissions = all permissions where `default_grant: true` in permissions.json
- Permission schema must be registered on BOTH service org (step 01) AND end-users org (step 04) — needed for `/permissions/user/{user_id}` queries
- Login config `default_role` must be `"member"` (not `"end_user"`) — role assignment triggers team auto-join
- Login config `default_team` is injected by this step — don't set it manually in hosted-login.json
- Team creation failure is non-fatal — the step continues with login config
- OAuth client on end-users org is separate from service org client (step 02)
- End-users org slug convention: `{service_id}-users`

## Step 05 — `authsetup --config-dir ./config status` (verify-setup)

**Purpose:** Comprehensive, read-only verification of all setup steps. This is the binary's `status` command (it replaces the old "verify"); it can also be run as `authsetup --config-dir ./config run 05`.

**Checks:**
1. Config files exist and have valid JSON + required fields
2. Credential files exist with required fields
3. Org hierarchy: end-users org parent_id matches service org_id
4. Auth service health endpoint
5. Hosted login endpoints return 200
6. Admin can authenticate and list org members
7. Permission model: default_role = "member"

**Exit code:** 0 if no FAILs, 1 if any FAIL

## Step 06 — `authsetup --config-dir ./config run 06` (test-end-user)

**Purpose:** End-to-end proof that a new user gets the right permissions.

**Process:**
1. Generate timestamped test user (`setup-test-{timestamp}@test-setup.example.com`)
2. Register via `POST /organizations/{eu_slug}/auth/register`
3. Verify org membership and active_org_id
4. Verify auto-joined default team
5. Check permissions via `GET /permissions/user/{user_id}` — all default_grant should be present
6. Verify admin-only permissions are NOT present

**Non-destructive:** Uses unique email each run, no cleanup needed.

## Step 07 — `authsetup --config-dir ./config run 07` (register-consumer)

**Purpose:** Register as a consumer of upstream mesh services (billing, payment, etc.). Drop a `clients.d/<provider>.json` into the config dir, then run step 07.

**Reads:** `config/clients.d/*.json`
**Outputs:** `~/.authmesh/<service-id>/{provider}-consumer.json` (or `{provider}-consumer-dev.json` for local auth)

**Process:**
1. Auto-discovers `clients.d/*.json` files in the config dir (or uses CLI args)
2. Reconciles each provider's consumer registration
3. Writes output to `~/.authmesh/<service-id>/` with `-consumer` suffix
4. Prints API key env vars to set

See the `mesh-service-accounts` skill for detailed coverage of step 07 and the consumer registration pattern.

## Environment Detection

Every step auto-detects dev vs prod:
- If `AUTH_SERVICE_URL` contains `localhost` or `dev.ab0t.com` → use `-dev` suffix for credential files
- Credential file lookup: try `{service_id}-dev.json` first, fall back to `{service_id}.json`
- This allows targeting multiple environments from the same directory

## Execution Order

`authsetup --config-dir ./config run` runs every step in order; a single `run 0X` requires the earlier steps' credentials to already exist. Each step depends on the previous:
```
01 (org + permissions)  →  standalone
02 (OAuth client)       →  requires 01 credentials
03 (hosted login)       →  requires 01 credentials
04 (end-users org)      →  requires 01 credentials + permissions.json + hosted-login.json
05 (verify)             →  requires 01-04 credentials
06 (test user)          →  requires 04 credentials
07 (consumer)           →  requires 01 credentials + provider credentials
```
