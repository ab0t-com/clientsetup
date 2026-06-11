# Troubleshooting

Common errors when running setup scripts and how to fix them.

## Registration Errors (Step 01)

### "Failed to create organization"

**Cause:** Slug collision — an org with that slug already exists but belongs to a different admin.

**Fix:**
1. Check `GET /users/me/organizations` for the slug
2. If found, the script should reuse it (check logs for "Found existing org")
3. If not found, another user owns it — change `service.id` in permissions.json

### "Failed to login as admin" after DB wipe

**Cause:** Cached credentials have a stale user/org that no longer exists.

**Fix:** Delete the credentials file and re-run:
```bash
rm credentials/{service_id}.json
rm credentials/{service_id}-dev.json
bash scripts/01-register-service-permissions.sh
```

### "Permission registration failed"

**Cause:** Permission IDs don't match expected format or the auth server doesn't recognize the action/resource.

**Fix:** Check `permissions.json`:
- Every ID must start with `{registration.service}.`
- Format: `{service}.{action}` or `{service}.{action}.{resource}`
- Actions and resources must be in the `registration.actions` / `registration.resources` arrays

## OAuth Errors (Step 02)

### "Client already exists" prompt

**Normal.** Script asks (U)pdate/(N)ew/(Q)uit in interactive mode. Choose U to update or N for a new client.

### "Update failed — registration_access_token missing"

**Cause:** Previous registration didn't save the RFC 7592 token.

**Fix:** Choose N (new) to create a fresh client. Old client stays valid.

## Hosted Login Errors (Step 03)

### "PUT login-config returned 404"

**Cause:** The org doesn't exist or the admin token doesn't have access.

**Fix:** Re-run step 01, then step 03.

### Login page shows wrong branding

**Cause:** Step 03 does a full replace — the last config applied wins.

**Fix:** Re-run step 03 with the correct `hosted-login.json`.

### "PUT login-config returned 400 — Login config validation failed"

**Cause:** A cross-field validation rejected the write. Most common: `security.accept_invite_url` or `security.accept_invite_error_url` has an origin that isn't in `security.accept_invite_allowed_origins`. Auth-service detail goes to its server logs (intentionally not surfaced in the client response).

**Fix:**
1. Run `./scripts/validate-config.sh` — it prints the offending field with the offending origin.
2. Either add the origin to `security.accept_invite_allowed_origins` or change the URL.
3. Different schemes count as different origins — `https://app.example.com` and `http://app.example.com` need separate allowlist entries.
4. Allowlist entries must be clean origins: `scheme://host[:port]` with no path, no trailing slash.

### Invite email link lands on a generic "this invitation link cannot be used" page

**Cause:** The org has no `security.accept_invite_url` configured, so `/accept-invite` falls back to the bundled error page. Backward-compatibility safety net — the underlying invitation row is still consumable via `POST /auth/register {invitation_code}`.

**Fix:** Set `security.accept_invite_url` and `security.accept_invite_allowed_origins` in `config/hosted-login.json`, then re-run step 03. See [oauth-hosted-login.md → Invitation-link landing](oauth-hosted-login.md#invitation-link-landing-securityaccept_invite_).

### Invite email points at a domain my customer's frontend doesn't host

**Cause:** Pre-PART3 invitation emails embedded `{FRONTEND_URL}/orgs/{slug}/accept-invite?code=`. Post-PART3 they embed `{AUTH_SERVICE_URL}/accept-invite?code=` and the auth service redirects to whatever the customer configured. If the redirect destination is wrong, fix it on the org's login_config — DON'T edit the email template.

**Fix:** Update `security.accept_invite_url` and re-run step 03.

## Default Team Errors (Step 04)

### "Failed to create end-users org"

**Cause:** Slug collision (`{service_id}-users` already exists) or admin token expired.

**Fix:** Re-run step 01 to refresh the admin token, then step 04.

### Users register but have no permissions

**Cause:** Most common — one of these is wrong:
1. Default team wasn't created (step 04 team creation failed)
2. Login config doesn't have `default_team` set
3. Login config `default_role` is not `"member"`
4. Permission schema not registered on end-users org

**Debugging:**
```bash
# Check login config has default_team
EU_SLUG=$(jq -r '.org_slug' credentials/end-users-org.json)
curl -s "https://auth.service.ab0t.com/organizations/$EU_SLUG/login-config/public" | jq '.registration'

# Check team exists and has permissions
EU_ID=$(jq -r '.org_id' credentials/end-users-org.json)
ADMIN_TOKEN="..."  # login as admin
curl -s -H "Authorization: Bearer $ADMIN_TOKEN" \
  "https://auth.service.ab0t.com/organizations/$EU_ID/teams" | jq '.[0].permissions'
```

**Fix:** Re-run step 04.

### "default_role must be 'member', not 'end_user'"

**Cause:** Step 05 verification catches this. The role `"end_user"` doesn't trigger team auto-join.

**Fix:** Re-run step 04 — it injects `default_role: "member"` into the login config.

## Verification Errors (Step 05)

### "Org hierarchy mismatch"

**Cause:** end-users org `parent_org_id` doesn't match service org `id`.

**Fix:** Delete end-users-org credentials and re-run step 04:
```bash
rm credentials/end-users-org*.json
bash scripts/04-setup-default-team.sh
```

### "Hosted login page returned non-200"

**Cause:** Auth service is down, or the org was deleted.

**Fix:** Check auth service health: `curl https://auth.service.ab0t.com/health`

## Test User Errors (Step 06)

### "User has 0 permissions"

**Cause:** Team auto-join didn't work. See "Users register but have no permissions" above.

### "User has admin permissions"

**Cause:** `default_grant: true` is set on admin-only permissions in permissions.json.

**Fix:** Set `"default_grant": false` on admin/dangerous permissions, re-run steps 01 and 04.

## After Auth DB Wipe

DynamoDB local loses everything on container restart. Full recovery:

```bash
# 1. Delete ALL stale credentials
rm -f credentials/*.json credentials/*.bak.*
rm -f scripts/service-client-setup/credentials/*.json

# 2. Re-run all steps in order
bash scripts/01-register-service-permissions.sh
bash scripts/02-register-oauth-client.sh
bash scripts/03-setup-hosted-login.sh
bash scripts/04-setup-default-team.sh
bash scripts/05-verify-setup.sh
bash scripts/06-test-end-user.sh
bash scripts/07-register-consumer.sh   # if consuming upstream services

# 3. Update .env with new API keys
# 4. Rebuild containers
```

## Quick Debug Checklist

```
[ ] Auth service healthy?
    curl https://auth.service.ab0t.com/health

[ ] Credentials files exist?
    ls credentials/*.json

[ ] Org IDs are valid (not stale)?
    ORG=$(jq -r '.organization.id' credentials/{service}.json)
    curl -s https://auth.service.ab0t.com/organizations/$ORG | jq .id

[ ] Admin can login?
    Use email/password from credentials/{service}.json

[ ] End-users org has correct parent?
    jq '{eu: .org_id, parent: .parent_org_id}' credentials/end-users-org.json

[ ] Default team has permissions?
    Run step 06 to test

[ ] Login config has default_team?
    Check /login-config/public endpoint
```
