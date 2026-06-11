#!/bin/bash
# Create an end-users child org with a default team for permission inheritance.
#
# ALTERNATIVE to 04-setup-end-users-org.sh — use ONE or the OTHER, not both.
#
#   04   = Org-based path: grants default_grant permissions directly to admin user
#   04.1 = Team-based path: creates a "Default Users" team, new users auto-join
#
# Architecture (team-based):
#   Service Org (platform_service)
#     └── End-Users Org (child, parent_id = service org)
#           ├── hosted login configured (users land here on signup)
#           ├── "Default Users" team (holds default_grant permissions)
#           │     ├── User A (auto-joined on registration)
#           │     └── User B (auto-joined on registration)
#           └── login config: default_team = {team_id}
#
#   Permissions flow through Zanzibar graph traversal:
#     user → team membership (relationship) → team permissions → ALLOWED
#
#   When a user registers:
#     1. Auth server reads login config → finds default_team
#     2. Calls add_team_member() → Zanzibar relationship written
#     3. Permission checks traverse: user → team → team's permissions
#     4. User has the right permissions immediately
#
#   When permissions change:
#     - Update the team's permissions array → Zanzibar sync handles the rest
#     - All team members inherit the change automatically
#     - No per-user grants to update
#
# This script:
#   1. Creates a child organization under the service org (with parent_id)
#   2. Creates a "Default Users" team with default_grant permissions
#   3. Registers the permission schema on the end-users org
#   4. Configures hosted login with default_team pointing to the team
#   5. Saves the result to credentials/end-users-org.json
#
# IDEMPOTENT: Detects existing org and team, skips creation.
#
# Prerequisites:
#   - credentials/{service}.json must exist (from 01-register-service-permissions.sh)
#   - config/permissions.json must exist
#   - config/hosted-login.json must exist
#   - jq, python3, curl must be available
#
# Usage:
#   ./scripts/04.1-setup-default-team.sh
#   AUTH_SERVICE_URL=https://auth.dev.ab0t.com ./scripts/04.1-setup-default-team.sh
#   DRY_RUN=1 ./scripts/04.1-setup-default-team.sh
#   SYNC_EXISTING=1 ./scripts/04.1-setup-default-team.sh    # sync perms even when team exists
#
# SYNC_EXISTING flag (added 2026-06-10):
#   By default this script SKIPS team mutation when the default team already
#   exists. That keeps re-runs cheap, but it means perms drift accumulates:
#   when the registry adds a NEW default_grant permission, existing teams
#   don't get it on re-run, so members never gain the perm.
#
#   With SYNC_EXISTING=1, an existing team's permissions get PUT-updated to
#   the UNION of (existing ∪ canonical default_grant set). Additive only —
#   we never remove a custom perm an operator added by hand.
#
#   SCOPE: this syncs the SHARED end-users team only (flat / self-service
#   archetypes). It does NOT reach the per-user workspace teams created by
#   org_structure.pattern = "workspace-per-user" — permission checks in a
#   user's workspace are scoped to THAT org and never see this team. For
#   existing workspaces use:
#       ./scripts/09-backfill-workspace-permissions.sh
#   (Re-running this script DOES refresh the workspace template in
#   login_config, so FUTURE workspaces are covered either way.)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_DIR="${SETUP_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
AUTH_SERVICE_URL="${AUTH_SERVICE_URL:-https://auth.service.ab0t.com}"
DRY_RUN="${DRY_RUN:-0}"
SYNC_EXISTING="${SYNC_EXISTING:-0}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Requirements
for cmd in jq python3 curl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo -e "${RED}ERROR: $cmd is required${NC}"
    exit 1
  fi
done

# Load configs
PERMISSIONS_FILE="${PERMISSIONS_FILE:-$SETUP_DIR/config/permissions.json}"
LOGIN_CONFIG_FILE="${LOGIN_CONFIG_FILE:-$SETUP_DIR/config/hosted-login.json}"

if [ ! -f "$PERMISSIONS_FILE" ]; then
  echo -e "${RED}ERROR: $PERMISSIONS_FILE not found${NC}"
  exit 1
fi

if [ ! -f "$LOGIN_CONFIG_FILE" ]; then
  echo -e "${RED}ERROR: $LOGIN_CONFIG_FILE not found${NC}"
  exit 1
fi

# Determine environment suffix
if echo "$AUTH_SERVICE_URL" | grep -qE "localhost|dev\.ab0t\.com"; then
  ENV_SUFFIX="-dev"
else
  ENV_SUFFIX=""
fi

# Load service credentials
SERVICE_ID="$(jq -r '.service.id' "$PERMISSIONS_FILE")"
CREDS_FILE="$SETUP_DIR/credentials/${SERVICE_ID}${ENV_SUFFIX}.json"

if [ ! -f "$CREDS_FILE" ] && [ -n "$ENV_SUFFIX" ]; then
  FALLBACK="$SETUP_DIR/credentials/${SERVICE_ID}.json"
  if [ -f "$FALLBACK" ]; then
    CREDS_FILE="$FALLBACK"
  fi
fi

# Try legacy name
if [ ! -f "$CREDS_FILE" ]; then
  CREDS_FILE="$SETUP_DIR/credentials/integration-service${ENV_SUFFIX}.json"
  if [ ! -f "$CREDS_FILE" ] && [ -n "$ENV_SUFFIX" ]; then
    CREDS_FILE="$SETUP_DIR/credentials/integration-service.json"
  fi
fi

if [ ! -f "$CREDS_FILE" ]; then
  echo -e "${RED}ERROR: No credentials found. Run 01-register-service-permissions.sh first.${NC}"
  exit 1
fi

SERVICE_ORG_ID="$(jq -r '.organization.id' "$CREDS_FILE")"
SERVICE_ORG_SLUG="$(jq -r '.organization.slug // .service' "$CREDS_FILE")"
SERVICE_NAME="$(jq -r '.service // "Service"' "$CREDS_FILE")"

OUTPUT_FILE="$SETUP_DIR/credentials/end-users-org${ENV_SUFFIX}.json"
END_USERS_SLUG="${SERVICE_ID}-users"
END_USERS_NAME="${SERVICE_NAME} Users"
# DEFAULT_TEAM_NAME="${DEFAULT_TEAM_NAME:-Default Users}"
DEFAULT_TEAM_NAME="${DEFAULT_TEAM_NAME:-$(jq -r '.end_users.default_team_name // "Default Users"' "$PERMISSIONS_FILE")}"

# Extract default_grant permissions from permissions.json
DEFAULT_PERMS="$(jq -r '.permissions[] | select(.default_grant == true) | .id' "$PERMISSIONS_FILE")"
DEFAULT_PERM_COUNT="$(echo "$DEFAULT_PERMS" | grep -c . || true)"
DEFAULT_PERMS_JSON="$(jq -c '[.permissions[] | select(.default_grant == true) | .id]' "$PERMISSIONS_FILE")"

# Determine the default role for end-users from permissions.json
EU_DEFAULT_ROLE="$(jq -r '(.roles[] | select(.default == true) | .id) // "member"' "$PERMISSIONS_FILE")"

# ─── Org Structure (end_users.org_structure) ─────────────────────────────
# Clients declare the pattern in permissions.json. We propagate it to the
# auth service's login_config so the event handler can read it at runtime.
# Default "flat" = no extra orgs on signup (safe, existing behavior).
#
# For "workspace-per-user":
#   1. Pre-substitute {service_id} in slug_template (handler only knows
#      runtime vars: {email_prefix}, {short_id}, {parent_org_id}).
#   2. If default_team_permissions not explicitly set, auto-populate from
#      default_grant: true permissions (so the workspace team mirrors the
#      end-users team unless the client overrides).
ORG_STRUCTURE_PATTERN="$(jq -r '.end_users.org_structure.pattern // "flat"' "$PERMISSIONS_FILE")"
ORG_STRUCTURE_CONFIG="$(jq -c '.end_users.org_structure.config // {}' "$PERMISSIONS_FILE")"

if [ "$ORG_STRUCTURE_PATTERN" = "workspace-per-user" ]; then
  # Pre-substitute {service_id} if the template uses it
  HAS_SLUG_TEMPLATE="$(echo "$ORG_STRUCTURE_CONFIG" | jq 'has("slug_template")')"
  if [ "$HAS_SLUG_TEMPLATE" = "true" ]; then
    CURRENT_SLUG_TPL="$(echo "$ORG_STRUCTURE_CONFIG" | jq -r '.slug_template')"
    SUBSTITUTED_SLUG_TPL="${CURRENT_SLUG_TPL//\{service_id\}/$SERVICE_ID}"
    ORG_STRUCTURE_CONFIG="$(echo "$ORG_STRUCTURE_CONFIG" | jq --arg s "$SUBSTITUTED_SLUG_TPL" '.slug_template = $s')"
  fi

  # Inject default_team_permissions from default_grant perms unless client provided
  HAS_TEAM_PERMS="$(echo "$ORG_STRUCTURE_CONFIG" | jq 'has("default_team_permissions")')"
  if [ "$HAS_TEAM_PERMS" = "false" ]; then
    ORG_STRUCTURE_CONFIG="$(echo "$ORG_STRUCTURE_CONFIG" | jq --argjson p "$DEFAULT_PERMS_JSON" '. + {default_team_permissions: $p}')"
  fi
fi

echo -e "${CYAN}=== End-Users Org Setup (Team-Based) ===${NC}"
echo ""
echo "Service Org:      $SERVICE_ORG_SLUG ($SERVICE_ORG_ID)"
echo "End-Users Org:    $END_USERS_SLUG"
echo "Default Role:     $EU_DEFAULT_ROLE"
echo "Default Team:     $DEFAULT_TEAM_NAME"
echo "Default Perms:    $DEFAULT_PERM_COUNT permissions (inherited via team membership)"
echo "Org Structure:    $ORG_STRUCTURE_PATTERN"
echo "Auth Service:     $AUTH_SERVICE_URL"
echo "Output:           $OUTPUT_FILE"
echo ""

if [ "$DRY_RUN" = "1" ]; then
  echo -e "${YELLOW}=== DRY RUN ===${NC}"
  echo "Would create child org: $END_USERS_SLUG (parent: $SERVICE_ORG_ID)"
  echo "Would create team: $DEFAULT_TEAM_NAME"
  echo "Would assign team permissions (inherited by all members):"
  echo "$DEFAULT_PERMS" | sed 's/^/  - /'
  echo "Would configure hosted login (default_role: $EU_DEFAULT_ROLE, default_team: <team_id>)"
  echo "Would set org_structure on login_config:"
  echo "  pattern: $ORG_STRUCTURE_PATTERN"
  if [ "$ORG_STRUCTURE_PATTERN" != "flat" ]; then
    echo "  config:  $(echo "$ORG_STRUCTURE_CONFIG" | jq -c .)"
    echo "  → Auth handler will materialize a $ORG_STRUCTURE_PATTERN structure for each new user"
  else
    echo "  (pattern 'flat' = no extra orgs created on signup; existing behavior preserved)"
  fi
  echo -e "${YELLOW}=== DRY RUN COMPLETE ===${NC}"
  exit 0
fi

# Step 1: Login as service admin
echo -e "${BLUE}Step 1: Logging in as service admin${NC}"

ACCESS_TOKEN="$(python3 << PYEOF
import json, urllib.request, ssl, sys

creds = json.load(open("$CREDS_FILE"))
data = json.dumps({
    "email": creds["admin"]["email"],
    "password": creds["admin"]["password"],
    "org_id": creds["organization"]["id"]
}).encode()

req = urllib.request.Request(
    "$AUTH_SERVICE_URL/auth/login",
    data=data,
    headers={"Content-Type": "application/json"}
)
try:
    resp = urllib.request.urlopen(req, context=ssl.create_default_context())
    print(json.loads(resp.read())["access_token"])
except urllib.error.HTTPError as e:
    print("FAILED:" + e.read().decode(), file=sys.stderr)
    sys.exit(1)
PYEOF
)"

if [ -z "$ACCESS_TOKEN" ]; then
  echo -e "${RED}Login failed${NC}"
  exit 1
fi
echo -e "${GREEN}Logged in${NC}"

# Step 2: Check if end-users org already exists
echo -e "${BLUE}Step 2: Checking for existing end-users org${NC}"

END_USERS_ORG_ID=""

# Check output file first
if [ -f "$OUTPUT_FILE" ]; then
  EXISTING_ID="$(jq -r '.org_id // empty' "$OUTPUT_FILE")"
  if [ -n "$EXISTING_ID" ]; then
    CHECK_CODE="$(curl -s -o /dev/null -w "%{http_code}" \
      "$AUTH_SERVICE_URL/organizations/$EXISTING_ID" \
      -H "Authorization: Bearer $ACCESS_TOKEN")"
    if [ "$CHECK_CODE" = "200" ]; then
      END_USERS_ORG_ID="$EXISTING_ID"
      echo -e "${GREEN}End-users org already exists: $END_USERS_ORG_ID${NC}"
    fi
  fi
fi

# Try to find by slug if not found
if [ -z "$END_USERS_ORG_ID" ]; then
  USER_ORGS="$(curl -s "$AUTH_SERVICE_URL/users/me/organizations" \
    -H "Authorization: Bearer $ACCESS_TOKEN" 2>/dev/null || echo "[]")"

  FOUND_ID="$(echo "$USER_ORGS" | jq -r '.[] | select(.slug=="'"$END_USERS_SLUG"'") | .id' 2>/dev/null | head -n1)"
  if [ -n "$FOUND_ID" ] && [ "$FOUND_ID" != "null" ]; then
    END_USERS_ORG_ID="$FOUND_ID"
    echo -e "${GREEN}Found existing end-users org: $END_USERS_ORG_ID${NC}"
  fi
fi

# Step 3: Create end-users org if needed
if [ -z "$END_USERS_ORG_ID" ]; then
  echo -e "${BLUE}Step 3: Creating end-users child org${NC}"

  CREATE_RESPONSE="$(curl -s -w "\nHTTP_CODE:%{http_code}" \
    -X POST "$AUTH_SERVICE_URL/organizations/" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{
      "name": "'"$END_USERS_NAME"'",
      "slug": "'"$END_USERS_SLUG"'",
      "parent_id": "'"$SERVICE_ORG_ID"'",
      "billing_type": "prepaid",
      "settings": {
        "type": "team",
        "service": "'"$SERVICE_ID"'",
        "purpose": "end_users"
      },
      "metadata": {
        "description": "End-users organization for '"$SERVICE_NAME"'",
        "created_by": "setup-cli"
      }
    }')"

  HTTP_CODE="$(echo "$CREATE_RESPONSE" | grep "HTTP_CODE" | cut -d: -f2)"
  RESPONSE_BODY="$(echo "$CREATE_RESPONSE" | grep -v "HTTP_CODE")"

  if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
    END_USERS_ORG_ID="$(echo "$RESPONSE_BODY" | jq -r '.id')"
    echo -e "${GREEN}Created end-users org: $END_USERS_ORG_ID${NC}"
    echo -e "${GREEN}  parent_id: $SERVICE_ORG_ID (Zanzibar parent relationship auto-created)${NC}"
  else
    echo -e "${RED}Failed to create end-users org (HTTP $HTTP_CODE)${NC}"
    echo "$RESPONSE_BODY" | jq . 2>/dev/null || echo "$RESPONSE_BODY"
    exit 1
  fi
else
  echo -e "${BLUE}Step 3: Skipped (org already exists)${NC}"
fi

# Step 4: Login with end-users org context
echo -e "${BLUE}Step 4: Getting end-users org context${NC}"

EU_LOGIN="$(curl -s -X POST "$AUTH_SERVICE_URL/auth/login" \
  -H "Content-Type: application/json" \
  -d "$(jq -n \
    --arg email "$(jq -r '.admin.email' "$CREDS_FILE")" \
    --arg password "$(jq -r '.admin.password' "$CREDS_FILE")" \
    --arg org_id "$END_USERS_ORG_ID" \
    '{email: $email, password: $password, org_id: $org_id}')")"

EU_TOKEN="$(echo "$EU_LOGIN" | jq -r '.access_token // empty')"

if [ -z "$EU_TOKEN" ]; then
  echo -e "${YELLOW}Could not login with end-users org context, using service admin token${NC}"
  EU_TOKEN="$ACCESS_TOKEN"
fi

echo -e "${GREEN}Got org context token${NC}"

# Step 5: Create default team with default_grant permissions
# New users auto-join this team on registration via login config default_team.
# Permissions flow through Zanzibar graph: user → team relationship → team permissions.
echo -e "${BLUE}Step 5: Creating default team with default_grant permissions${NC}"

DEFAULT_TEAM_ID=""

# Check if team already exists (idempotent)
EXISTING_TEAMS="$(curl -s "$AUTH_SERVICE_URL/organizations/$END_USERS_ORG_ID/teams" \
  -H "Authorization: Bearer $EU_TOKEN" 2>/dev/null || echo "[]")"

FOUND_TEAM="$(echo "$EXISTING_TEAMS" | jq -r '.[] | select(.name=="'"$DEFAULT_TEAM_NAME"'") | .id' 2>/dev/null | head -n1)"

if [ -n "$FOUND_TEAM" ] && [ "$FOUND_TEAM" != "null" ]; then
  DEFAULT_TEAM_ID="$FOUND_TEAM"
  echo -e "${GREEN}Default team already exists: $DEFAULT_TEAM_ID${NC}"

  # When SYNC_EXISTING=1, bring the existing team's permissions up to date
  # with the current registry's default_grant set. Computes the UNION so
  # operator-added custom perms are preserved. No-op when nothing's new.
  if [ "$SYNC_EXISTING" = "1" ]; then
    EXISTING_PERMS="$(echo "$EXISTING_TEAMS" \
      | jq -c '.[] | select(.name=="'"$DEFAULT_TEAM_NAME"'") | .permissions // []' 2>/dev/null | head -n1)"
    # Guard: a shape surprise can yield an empty string, and `--argjson cur ""`
    # is a jq error that kills the run under `set -euo pipefail`.
    EXISTING_PERMS="${EXISTING_PERMS:-[]}"
    TARGET_PERMS="$(jq -c --argjson cur "$EXISTING_PERMS" --argjson new "$DEFAULT_PERMS_JSON" \
      -n '$cur + $new | unique')"
    # Set difference (not length subtraction): dup-safe, and tells the
    # operator exactly WHICH perms are being added.
    MISSING_PERMS="$(jq -cn --argjson cur "$EXISTING_PERMS" --argjson tgt "$TARGET_PERMS" \
      '$tgt - $cur')"
    ADDED_COUNT="$(echo "$MISSING_PERMS" | jq 'length')"

    if [ "$ADDED_COUNT" -gt 0 ]; then
      echo -e "${CYAN}  SYNC_EXISTING=1: adding $ADDED_COUNT new default_grant perm(s) to existing team${NC}"
      echo -e "${CYAN}    $(echo "$MISSING_PERMS" | jq -cr '.')${NC}"
      SYNC_RESPONSE="$(curl -s -w "\nHTTP_CODE:%{http_code}" \
        -X PUT "$AUTH_SERVICE_URL/teams/$DEFAULT_TEAM_ID" \
        -H "Authorization: Bearer $EU_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"permissions\": $TARGET_PERMS}")"
      SYNC_HTTP_CODE="$(echo "$SYNC_RESPONSE" | grep "HTTP_CODE" | cut -d: -f2)"
      SYNC_BODY="$(echo "$SYNC_RESPONSE" | grep -v "HTTP_CODE")"
      if [ "$SYNC_HTTP_CODE" = "200" ] || [ "$SYNC_HTTP_CODE" = "201" ]; then
        echo -e "${GREEN}  Synced existing team permissions ($ADDED_COUNT new added)${NC}"
        echo -e "${GREEN}  Members see the change within ~5 min (permission cache TTL); a fresh login applies immediately.${NC}"
      else
        echo -e "${YELLOW}  Sync PUT returned HTTP $SYNC_HTTP_CODE — continuing${NC}"
        echo "$SYNC_BODY" | jq . 2>/dev/null || echo "$SYNC_BODY"
      fi
    else
      echo -e "${GREEN}  SYNC_EXISTING=1: team already carries all canonical perms (no-op)${NC}"
    fi
  fi
else
  TEAM_RESPONSE="$(curl -s -w "\nHTTP_CODE:%{http_code}" \
    -X POST "$AUTH_SERVICE_URL/organizations/$END_USERS_ORG_ID/teams" \
    -H "Authorization: Bearer $EU_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{
      "name": "'"$DEFAULT_TEAM_NAME"'",
      "description": "Auto-join team — new users get these permissions on registration",
      "permissions": '"$DEFAULT_PERMS_JSON"'
    }')"

  HTTP_CODE="$(echo "$TEAM_RESPONSE" | grep "HTTP_CODE" | cut -d: -f2)"
  TEAM_BODY="$(echo "$TEAM_RESPONSE" | grep -v "HTTP_CODE")"

  if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
    DEFAULT_TEAM_ID="$(echo "$TEAM_BODY" | jq -r '.id // .team_id')"
    echo -e "${GREEN}Default team created: $DEFAULT_TEAM_ID${NC}"
    echo -e "${GREEN}  Permissions: $DEFAULT_PERM_COUNT default_grant permissions assigned${NC}"
  else
    echo -e "${RED}Failed to create default team (HTTP $HTTP_CODE)${NC}"
    echo "$TEAM_BODY" | jq . 2>/dev/null || echo "$TEAM_BODY"
    echo -e "${YELLOW}Continuing without default team — users will need manual team assignment${NC}"
  fi
fi

# Step 6: Register permission schema on end-users org
echo -e "${BLUE}Step 6: Registering permission schema${NC}"

REG_SERVICE="$(jq -r '.registration.service // .service.id' "$PERMISSIONS_FILE")"
REG_ACTIONS="$(jq -c '.registration.actions // []' "$PERMISSIONS_FILE")"
REG_RESOURCES="$(jq -c '.registration.resources // []' "$PERMISSIONS_FILE")"
SERVICE_DESC="$(jq -r '.service.description // .service.name' "$PERMISSIONS_FILE")"

PERM_RESPONSE="$(curl -s -w "\nHTTP_CODE:%{http_code}" -X POST "$AUTH_SERVICE_URL/permissions/registry/register" \
  -H "Authorization: Bearer $EU_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "service": "'"$REG_SERVICE"'",
    "description": "'"$SERVICE_DESC"'",
    "actions": '"$REG_ACTIONS"',
    "resources": '"$REG_RESOURCES"'
  }')"

HTTP_CODE="$(echo "$PERM_RESPONSE" | grep "HTTP_CODE" | cut -d: -f2)"
PERM_REGISTRY_BODY="$(echo "$PERM_RESPONSE" | grep -v "HTTP_CODE")"

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
  echo -e "${GREEN}Permission schema registered on end-users org${NC}"
else
  echo -e "${YELLOW}Permission registry returned HTTP $HTTP_CODE (non-fatal)${NC}"
fi

# Step 7: Configure hosted login on end-users org
# default_role  = "member" (has api.read + org.read + api.write from role)
# default_team  = team_id  (new users auto-join → inherit team permissions)
echo -e "${BLUE}Step 7: Configuring hosted login on end-users org${NC}"

if [ -n "$DEFAULT_TEAM_ID" ]; then
  EU_LOGIN_CONFIG="$(jq \
    --arg team_id "$DEFAULT_TEAM_ID" \
    --arg structure_pattern "$ORG_STRUCTURE_PATTERN" \
    --argjson structure_config "$ORG_STRUCTURE_CONFIG" \
    '.registration.default_role = "member"
     | .registration.default_team = $team_id
     | .registration.org_structure = {pattern: $structure_pattern, config: $structure_config}' \
    "$LOGIN_CONFIG_FILE")"
  echo "  default_role:   member"
  echo "  default_team:   $DEFAULT_TEAM_ID"
  echo "  org_structure:  $ORG_STRUCTURE_PATTERN"
else
  EU_LOGIN_CONFIG="$(jq \
    --arg structure_pattern "$ORG_STRUCTURE_PATTERN" \
    --argjson structure_config "$ORG_STRUCTURE_CONFIG" \
    '.registration.default_role = "member"
     | .registration.org_structure = {pattern: $structure_pattern, config: $structure_config}' \
    "$LOGIN_CONFIG_FILE")"
  echo "  default_role:   member"
  echo -e "  ${YELLOW}default_team:   (none — team creation failed)${NC}"
  echo "  org_structure:  $ORG_STRUCTURE_PATTERN"
fi

CONFIG_RESPONSE="$(curl -s -w "\nHTTP_CODE:%{http_code}" \
  -X PUT "$AUTH_SERVICE_URL/organizations/$END_USERS_ORG_ID/login-config" \
  -H "Authorization: Bearer $EU_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$EU_LOGIN_CONFIG")"

HTTP_CODE="$(echo "$CONFIG_RESPONSE" | grep "HTTP_CODE" | cut -d: -f2)"
LOGIN_CONFIG_PUT_BODY="$(echo "$CONFIG_RESPONSE" | grep -v "HTTP_CODE")"

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
  echo -e "${GREEN}Hosted login configured${NC}"
else
  echo -e "${YELLOW}Login config returned HTTP $HTTP_CODE (may need manual setup)${NC}"
fi

# Step 8: Verify hosted login page
echo -e "${BLUE}Step 8: Verifying hosted login page${NC}"

HOSTED_CODE="$(curl -s -o /dev/null -w "%{http_code}" "$AUTH_SERVICE_URL/login/$END_USERS_SLUG")"
if [ "$HOSTED_CODE" = "200" ]; then
  echo -e "${GREEN}Hosted login page OK: $AUTH_SERVICE_URL/login/$END_USERS_SLUG${NC}"
else
  echo -e "${YELLOW}Hosted login page returned HTTP $HOSTED_CODE${NC}"
fi

# Step 8b: Register OAuth client on end-users org
# Users auth via /organizations/{end-users-slug}/auth/authorize — client must belong to THIS org.
echo -e "${BLUE}Step 8b: Registering OAuth client on end-users org${NC}"

OAUTH_CONFIG_FILE="${OAUTH_CONFIG_FILE:-$SETUP_DIR/config/oauth-client.json}"
# Per RFC 7592, every dynamically-registered client is managed via the
# (registration_client_uri, registration_access_token) pair returned at
# creation time. Persist it on POST so subsequent runs can reconcile the
# client (e.g., update redirect_uris) using the right credentials.
EU_OAUTH_CLIENT_FILE="$SETUP_DIR/credentials/end-users-oauth-client${ENV_SUFFIX}.json"
EU_OAUTH_CLIENT_ID=""

if [ -f "$OAUTH_CONFIG_FILE" ]; then
  CLIENT_NAME="$(jq -r '.client_name // "Frontend"' "$OAUTH_CONFIG_FILE")"
  REDIRECT_URIS="$(jq -c '.redirect_uris // []' "$OAUTH_CONFIG_FILE")"

  # Check if we already have a client registered on this org
  EXISTING_EU_CLIENTS="$(curl -s "$AUTH_SERVICE_URL/organizations/$END_USERS_ORG_ID/clients" \
    -H "Authorization: Bearer $EU_TOKEN" 2>/dev/null || echo "[]")"

  # Look for our client by name
  EU_OAUTH_CLIENT_ID="$(echo "$EXISTING_EU_CLIENTS" | jq -r \
    '.[] | select(.client_name == "'"$CLIENT_NAME"'") | .client_id' 2>/dev/null | head -n1)"

  if [ -n "$EU_OAUTH_CLIENT_ID" ] && [ "$EU_OAUTH_CLIENT_ID" != "null" ]; then
    echo -e "${GREEN}OAuth client already registered on end-users org: $EU_OAUTH_CLIENT_ID${NC}"

    # Check if redirect_uris need updating (idempotent update)
    CURRENT_URIS="$(echo "$EXISTING_EU_CLIENTS" | jq -c \
      '.[] | select(.client_id == "'"$EU_OAUTH_CLIENT_ID"'") | .redirect_uris // []' 2>/dev/null)"

    # Sort both for comparison
    CURRENT_SORTED="$(echo "$CURRENT_URIS" | jq -c 'sort')"
    CONFIG_SORTED="$(echo "$REDIRECT_URIS" | jq -c 'sort')"

    if [ "$CURRENT_SORTED" != "$CONFIG_SORTED" ]; then
      echo -e "${YELLOW}  Redirect URIs differ from config, updating...${NC}"

      # Per RFC 7592, the management endpoint is `registration_client_uri`
      # and authentication uses `registration_access_token` (not the org
      # admin Bearer). Both were returned at creation; we read them from
      # credentials/end-users-oauth-client.json (saved on POST below).
      RAT=""; RCU=""
      if [ -f "$EU_OAUTH_CLIENT_FILE" ]; then
        SAVED_ID="$(jq -r '.client_id // empty' "$EU_OAUTH_CLIENT_FILE")"
        if [ "$SAVED_ID" = "$EU_OAUTH_CLIENT_ID" ]; then
          RAT="$(jq -r '.registration_access_token // empty' "$EU_OAUTH_CLIENT_FILE")"
          RCU="$(jq -r '.registration_client_uri // empty' "$EU_OAUTH_CLIENT_FILE")"
        fi
      fi

      if [ -z "$RAT" ] || [ -z "$RCU" ]; then
        echo -e "${YELLOW}  No registration_access_token saved for $EU_OAUTH_CLIENT_ID${NC}"
        echo -e "${YELLOW}  This client was created before token persistence was added.${NC}"
        echo -e "${YELLOW}  Options: (a) delete the client manually and rerun this step to recreate it,${NC}"
        echo -e "${YELLOW}           (b) register a separate client with a different client_name,${NC}"
        echo -e "${YELLOW}           (c) leave redirect_uris as-is.${NC}"
      else
        UPDATE_RESPONSE="$(curl -s -w "\nHTTP_CODE:%{http_code}" \
          -X PUT "$RCU" \
          -H "Authorization: Bearer $RAT" \
          -H "Content-Type: application/json" \
          -d "$(jq -n \
            --arg client_id "$EU_OAUTH_CLIENT_ID" \
            --arg client_name "$CLIENT_NAME" \
            --argjson redirect_uris "$REDIRECT_URIS" \
            '{client_id:$client_id, client_name:$client_name, redirect_uris:$redirect_uris, grant_types:["authorization_code","refresh_token"], response_types:["code"], token_endpoint_auth_method:"none"}')")"

        HTTP_CODE="$(echo "$UPDATE_RESPONSE" | grep "HTTP_CODE" | cut -d: -f2)"
        UPDATE_BODY="$(echo "$UPDATE_RESPONSE" | grep -v "HTTP_CODE")"

        if [ "$HTTP_CODE" = "200" ]; then
          echo -e "${GREEN}  Redirect URIs updated${NC}"
          # PUT returns the full client object — refresh our saved copy so we
          # always have the latest metadata (registration_access_token may
          # have rotated per RFC 7592 §3).
          echo "$UPDATE_BODY" | jq . > "$EU_OAUTH_CLIENT_FILE"
          chmod 600 "$EU_OAUTH_CLIENT_FILE" 2>/dev/null || true
        else
          echo -e "${YELLOW}  Could not update redirect_uris (HTTP $HTTP_CODE)${NC}"
          echo "$UPDATE_BODY" | jq . 2>/dev/null || echo "$UPDATE_BODY"
        fi
      fi
    else
      echo -e "${GREEN}  Redirect URIs match config${NC}"
    fi
  else
    REG_RESPONSE="$(curl -s -w "\nHTTP_CODE:%{http_code}" \
      -X POST "$AUTH_SERVICE_URL/auth/oauth/register" \
      -H "Authorization: Bearer $EU_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$(jq -n \
        --arg org_id "$END_USERS_ORG_ID" \
        --arg client_name "$CLIENT_NAME" \
        --argjson redirect_uris "$REDIRECT_URIS" \
        '{org_id:$org_id, client_name:$client_name, redirect_uris:$redirect_uris, grant_types:["authorization_code","refresh_token"], response_types:["code"], token_endpoint_auth_method:"none", application_type:"web"}')")"

    HTTP_CODE="$(echo "$REG_RESPONSE" | grep "HTTP_CODE" | cut -d: -f2)"
    REG_BODY="$(echo "$REG_RESPONSE" | grep -v "HTTP_CODE")"

    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
      EU_OAUTH_CLIENT_ID="$(echo "$REG_BODY" | jq -r '.client_id')"
      echo -e "${GREEN}OAuth client registered on end-users org: $EU_OAUTH_CLIENT_ID${NC}"
      # Persist the full RFC 7591 response so future runs can manage this
      # client via RFC 7592 (registration_client_uri + registration_access_token).
      mkdir -p "$(dirname "$EU_OAUTH_CLIENT_FILE")"
      echo "$REG_BODY" | jq . > "$EU_OAUTH_CLIENT_FILE"
      chmod 600 "$EU_OAUTH_CLIENT_FILE" 2>/dev/null || true
      echo -e "${GREEN}  Saved management credentials to: $EU_OAUTH_CLIENT_FILE${NC}"
    else
      echo -e "${YELLOW}OAuth client registration returned HTTP $HTTP_CODE (non-fatal)${NC}"
      echo "$REG_BODY" | jq . 2>/dev/null || echo "$REG_BODY"
    fi
  fi
else
  echo -e "${YELLOW}No oauth-client.json config found, skipping${NC}"
fi

# Step 9: Save result
echo -e "${BLUE}Step 9: Saving result${NC}"

# Preserve raw responses from every state-changing call so future runs
# can verify what the server accepted vs what we requested. See
# SUGGESTIONS.md for rationale.
_safe_json() {
  printf '%s' "${1:-}" | jq -e . >/dev/null 2>&1 && printf '%s' "$1" || printf '{}'
}

RAW_TEAM_CREATE="$(_safe_json "${TEAM_BODY:-}")"
RAW_PERM_REGISTRY="$(_safe_json "${PERM_REGISTRY_BODY:-}")"
RAW_LOGIN_CONFIG_PUT="$(_safe_json "${LOGIN_CONFIG_PUT_BODY:-}")"

mkdir -p "$SETUP_DIR/credentials"

jq -n \
  --arg org_id "$END_USERS_ORG_ID" \
  --arg org_slug "$END_USERS_SLUG" \
  --arg org_name "$END_USERS_NAME" \
  --arg parent_org_id "$SERVICE_ORG_ID" \
  --arg parent_org_slug "$SERVICE_ORG_SLUG" \
  --arg default_role "member" \
  --arg default_team_id "${DEFAULT_TEAM_ID:-}" \
  --arg default_team_name "$DEFAULT_TEAM_NAME" \
  --arg oauth_client_id "${EU_OAUTH_CLIENT_ID:-}" \
  --arg url "$AUTH_SERVICE_URL" \
  --arg login_url "$AUTH_SERVICE_URL/login/$END_USERS_SLUG" \
  --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg structure_pattern "$ORG_STRUCTURE_PATTERN" \
  --argjson structure_config "$ORG_STRUCTURE_CONFIG" \
  --argjson default_permissions "$DEFAULT_PERMS_JSON" \
  --argjson raw_team_create "$RAW_TEAM_CREATE" \
  --argjson raw_perm_registry "$RAW_PERM_REGISTRY" \
  --argjson raw_login_config_put "$RAW_LOGIN_CONFIG_PUT" \
  '{
    org_id: $org_id,
    org_slug: $org_slug,
    org_name: $org_name,
    parent_org_id: $parent_org_id,
    parent_org_slug: $parent_org_slug,
    default_role: $default_role,
    default_team_id: $default_team_id,
    default_team_name: $default_team_name,
    oauth_client_id: $oauth_client_id,
    hosted_login_url: $login_url,
    default_permissions: $default_permissions,
    permission_model: "team-inherited",
    org_structure: {
      pattern: $structure_pattern,
      config: $structure_config
    },
    _meta: {
      auth_service_url: $url,
      created_at: $date,
      script: "04-setup-default-team.sh",
      note: "Permissions flow through Zanzibar team membership. New users auto-join the default team on registration. If org_structure.pattern is non-flat, the auth service event handler also materializes the configured structure for each new user."
    },
    _raw: {
      team_create: $raw_team_create,
      permissions_registry_register: $raw_perm_registry,
      login_config_put: $raw_login_config_put
    }
  }' > "$OUTPUT_FILE"

echo -e "${GREEN}Saved to: $OUTPUT_FILE${NC}"

echo ""
echo -e "${CYAN}=== End-Users Org Setup Complete (Team-Based) ===${NC}"
echo ""
echo "End-Users Org ID:   $END_USERS_ORG_ID"
echo "End-Users Slug:     $END_USERS_SLUG"
echo "Parent Org:         $SERVICE_ORG_SLUG ($SERVICE_ORG_ID)"
echo "Default Team:       $DEFAULT_TEAM_NAME (${DEFAULT_TEAM_ID:-FAILED})"
echo "Default Role:       member"
echo "Org Structure:      $ORG_STRUCTURE_PATTERN"
echo "OAuth Client:       ${EU_OAUTH_CLIENT_ID:-none}"
echo "Hosted Login:       $AUTH_SERVICE_URL/login/$END_USERS_SLUG"
echo "Permissions:        $DEFAULT_PERM_COUNT inherited via team membership"
echo ""
if [ -n "${EU_OAUTH_CLIENT_ID:-}" ]; then
  echo "Frontend auth-init.js should use:"
  echo "  clientId: '$EU_OAUTH_CLIENT_ID'"
  echo "  org: '$END_USERS_SLUG'"
  echo ""
fi
echo "How permissions work:"
echo "  1. User signs up at $AUTH_SERVICE_URL/login/$END_USERS_SLUG"
echo "  2. Auth server creates membership in end-users org (role: member)"
echo "  3. Auth server reads login config → default_team is set"
echo "  4. User auto-joins '$DEFAULT_TEAM_NAME' team"
echo "  5. Zanzibar resolves: user → team membership → team permissions"
echo "  6. User has all $DEFAULT_PERM_COUNT default_grant permissions immediately"
if [ "$ORG_STRUCTURE_PATTERN" = "workspace-per-user" ]; then
  echo "  7. Auth service handler creates a private workspace org for the user"
  echo "     (parent: end-users org, owner: the new user, with its own default team)"
fi
echo ""
if [ "$ORG_STRUCTURE_PATTERN" != "flat" ]; then
  echo "Org structure: $ORG_STRUCTURE_PATTERN"
  echo "  Each new user gets their own workspace materialized by the auth service"
  echo "  event handler. See README's 'Org Structures' section for details."
  echo ""
fi
echo "To change default permissions:"
echo "  Update the '$DEFAULT_TEAM_NAME' team's permissions array."
echo "  All current and future members inherit the change automatically."
echo ""
echo "Update your frontend login URL to:"
echo "  $AUTH_SERVICE_URL/login/$END_USERS_SLUG"
echo ""
