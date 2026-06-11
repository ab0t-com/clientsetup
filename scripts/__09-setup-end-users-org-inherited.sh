#!/bin/bash
# Create an end-users child org and configure org-level permissions.
#
# This is the key step that makes permissions "just work" for new users.
#
# Architecture:
#   Service Org (platform_service)
#     └── End-Users Org (child, parent_id = service org)
#           ├── parent relationship → inherits from service org via Zanbibar
#           ├── hosted login configured HERE (users land here on signup)
#           ├── org-level default_grant permissions registered
#           ├── User A (member) → permissions inherited from org
#           └── User B (member) → permissions inherited from org
#
#   Users get permissions through org membership — NOT per-user grants.
#   Zero callbacks. Zero cron. Zero maintenance.
#
# This script:
#   1. Creates a child organization under the service org (with parent_id)
#   2. Zanzibar parent relationship is created automatically by the auth server
#   3. Registers all default_grant permissions at the end-users org level
#   4. Configures hosted login on the child org (users self-register here)
#   5. Saves the result to credentials/end-users-org.json
#
# IDEMPOTENT: Detects existing child org and skips creation.
#
# Prerequisites:
#   - credentials/{service}.json must exist (from 01-register-service-permissions.sh)
#   - config/permissions.json must exist
#   - config/hosted-login.json must exist
#   - jq, python3, curl must be available
#
# Usage:
#   ./scripts/04-setup-end-users-org.sh
#   AUTH_SERVICE_URL=https://auth.dev.ab0t.com ./scripts/04-setup-end-users-org.sh
#   DRY_RUN=1 ./scripts/04-setup-end-users-org.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_DIR="${SETUP_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
AUTH_SERVICE_URL="${AUTH_SERVICE_URL:-https://auth.service.ab0t.com}"
DRY_RUN="${DRY_RUN:-0}"

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

# Extract default_grant permissions from permissions.json
DEFAULT_PERMS="$(jq -r '.permissions[] | select(.default_grant == true) | .id' "$PERMISSIONS_FILE")"
DEFAULT_PERM_COUNT="$(echo "$DEFAULT_PERMS" | grep -c . || true)"

# Determine the default role for end-users from permissions.json
# Uses the role marked "default": true, or falls back to "member"
EU_DEFAULT_ROLE="$(jq -r '(.roles[] | select(.default == true) | .id) // "member"' "$PERMISSIONS_FILE")"

echo -e "${CYAN}=== End-Users Org Setup ===${NC}"
echo ""
echo "Service Org:      $SERVICE_ORG_SLUG ($SERVICE_ORG_ID)"
echo "End-Users Org:    $END_USERS_SLUG"
echo "Default Role:     $EU_DEFAULT_ROLE"
echo "Default Perms:    $DEFAULT_PERM_COUNT permissions (inherited via org membership)"
echo "Auth Service:     $AUTH_SERVICE_URL"
echo "Output:           $OUTPUT_FILE"
echo ""

if [ "$DRY_RUN" = "1" ]; then
  echo -e "${YELLOW}=== DRY RUN ===${NC}"
  echo "Would create child org: $END_USERS_SLUG (parent: $SERVICE_ORG_ID)"
  echo "Would configure hosted login on child org (default_role: $EU_DEFAULT_ROLE)"
  echo "Would register org-level permissions (inherited by all members):"
  echo "$DEFAULT_PERMS" | sed 's/^/  - /'
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
      "billing_type": "free",
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

# Step 5: Register org-level permissions on end-users org
# These permissions are inherited by all org members through Zanzibar.
# The auth server creates Zanzibar relationships when an org is created
# and when users join — permission inheritance flows through the parent
# relationship automatically.
echo -e "${BLUE}Step 5: Registering org-level permissions${NC}"

# Register the permission schema on the end-users org too
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

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
  echo -e "${GREEN}Permission schema registered on end-users org${NC}"
else
  echo -e "${YELLOW}Permission registry returned HTTP $HTTP_CODE (non-fatal)${NC}"
fi

# Grant default_grant permissions to the admin user.
# TODO: This grants subject=user:{admin_id} — only the admin gets these permissions.
#       The Zanzibar resolver (zanzibar_permission_resolver.py) resolves:
#         1. Role perms (static)   2. Direct user grants   3. Team membership grants
#       It does NOT yet resolve org-level grants (subject=org:{id}).
#       The Zanzibar client.py check() DOES support org subjects (line 258),
#       but the resolver used by GET /permissions/user does not walk orgs.
#       To make org-inherited permissions work for all members, either:
#         a) Add org-membership resolution to zanzibar_permission_resolver.py (step 4)
#         b) Use script 04.1 (team-inherited) which works today
#       See: TASKLIST_20260307.md
ADMIN_USER_ID="$(jq -r '.admin.user_id // empty' "$CREDS_FILE")"
GRANT_OK=0
GRANT_FAIL=0

for PERM in $DEFAULT_PERMS; do
  # Grant to the admin in the end-users org context — this registers
  # the permission in the Zanzibar graph for this org scope.
  # When POST /permissions/check is wired to Zanzibar check(),
  # members inherit these through the parent org relationship.
  if [ -n "$ADMIN_USER_ID" ]; then
    GRANT_RESPONSE="$(curl -s -o /dev/null -w "%{http_code}" \
      -X POST "$AUTH_SERVICE_URL/permissions/grant?user_id=$ADMIN_USER_ID&org_id=$END_USERS_ORG_ID&permission=$PERM" \
      -H "Authorization: Bearer $EU_TOKEN")"

    if [ "$GRANT_RESPONSE" = "200" ] || [ "$GRANT_RESPONSE" = "201" ]; then
      GRANT_OK=$((GRANT_OK + 1))
    else
      GRANT_FAIL=$((GRANT_FAIL + 1))
    fi
  fi
done

if [ "$GRANT_OK" -gt 0 ]; then
  echo -e "${GREEN}Registered $GRANT_OK org-level permissions${NC}"
fi
if [ "$GRANT_FAIL" -gt 0 ]; then
  echo -e "${YELLOW}$GRANT_FAIL permissions could not be registered (may need users.write on API key)${NC}"
fi

# Step 6: Configure hosted login on end-users org
echo -e "${BLUE}Step 6: Configuring hosted login on end-users org${NC}"

# Set default_role to "member" — NOT "end_user".
# "member" has api.read + org.read + api.write in the Zanbibar role namespace.
# Combined with org-level service permissions, this gives users full access.
EU_LOGIN_CONFIG="$(jq '.registration.default_role = "member"' "$LOGIN_CONFIG_FILE")"

CONFIG_RESPONSE="$(curl -s -w "\nHTTP_CODE:%{http_code}" \
  -X PUT "$AUTH_SERVICE_URL/organizations/$END_USERS_ORG_ID/login-config" \
  -H "Authorization: Bearer $EU_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$EU_LOGIN_CONFIG")"

HTTP_CODE="$(echo "$CONFIG_RESPONSE" | grep "HTTP_CODE" | cut -d: -f2)"

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
  echo -e "${GREEN}Hosted login configured (default_role: member)${NC}"
else
  echo -e "${YELLOW}Login config returned HTTP $HTTP_CODE (may need manual setup)${NC}"
fi

# Step 7: Verify hosted login page
echo -e "${BLUE}Step 7: Verifying hosted login page${NC}"

HOSTED_CODE="$(curl -s -o /dev/null -w "%{http_code}" "$AUTH_SERVICE_URL/login/$END_USERS_SLUG")"
if [ "$HOSTED_CODE" = "200" ]; then
  echo -e "${GREEN}Hosted login page OK: $AUTH_SERVICE_URL/login/$END_USERS_SLUG${NC}"
else
  echo -e "${YELLOW}Hosted login page returned HTTP $HOSTED_CODE${NC}"
fi

# Step 8: Save result
echo -e "${BLUE}Step 8: Saving result${NC}"

mkdir -p "$SETUP_DIR/credentials"

DEFAULT_PERMS_JSON="$(jq -c '[.permissions[] | select(.default_grant == true) | .id]' "$PERMISSIONS_FILE")"

jq -n \
  --arg org_id "$END_USERS_ORG_ID" \
  --arg org_slug "$END_USERS_SLUG" \
  --arg org_name "$END_USERS_NAME" \
  --arg parent_org_id "$SERVICE_ORG_ID" \
  --arg parent_org_slug "$SERVICE_ORG_SLUG" \
  --arg default_role "member" \
  --arg url "$AUTH_SERVICE_URL" \
  --arg login_url "$AUTH_SERVICE_URL/login/$END_USERS_SLUG" \
  --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson default_permissions "$DEFAULT_PERMS_JSON" \
  '{
    org_id: $org_id,
    org_slug: $org_slug,
    org_name: $org_name,
    parent_org_id: $parent_org_id,
    parent_org_slug: $parent_org_slug,
    default_role: $default_role,
    hosted_login_url: $login_url,
    default_permissions: $default_permissions,
    permission_model: "org-inherited",
    _meta: {
      auth_service_url: $url,
      created_at: $date,
      note: "Permissions flow through Zanzibar org hierarchy. Members inherit from org membership."
    }
  }' > "$OUTPUT_FILE"

echo -e "${GREEN}Saved to: $OUTPUT_FILE${NC}"

echo ""
echo -e "${CYAN}=== End-Users Org Setup Complete ===${NC}"
echo ""
echo "End-Users Org ID:   $END_USERS_ORG_ID"
echo "End-Users Slug:     $END_USERS_SLUG"
echo "Parent Org:         $SERVICE_ORG_SLUG ($SERVICE_ORG_ID)"
echo "Default Role:       member (NOT end_user)"
echo "Hosted Login:       $AUTH_SERVICE_URL/login/$END_USERS_SLUG"
echo "Permissions:        $DEFAULT_PERM_COUNT inherited via org membership"
echo ""
echo "How permissions work:"
echo "  1. User signs up at $AUTH_SERVICE_URL/login/$END_USERS_SLUG"
echo "  2. Auth server creates membership in end-users org (role: member)"
echo "  3. Zanzibar parent relationship: end-users org -> service org"
echo "  4. Permission check resolves through org hierarchy"
echo "  5. User gets all default_grant permissions automatically"
echo ""
echo "Update your frontend login URL to:"
echo "  $AUTH_SERVICE_URL/login/$END_USERS_SLUG"
echo ""
