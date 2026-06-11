#!/bin/bash
# End-to-end test: prove a new user can sign up and has permissions.
#
# This script simulates the complete end-user journey:
#   1. Registers a new user via the end-users org hosted login API
#   2. Verifies the user auto-joined the default team
#   3. Verifies the user has all default_grant permissions
#   4. Verifies the user does NOT have admin permissions
#   5. Reports PASS/FAIL with actionable diagnostics
#
# This is the proof that the setup actually works — not just that
# endpoints are reachable, but that a real stranger can sign up
# and use the service.
#
# IDEMPOTENT: Uses timestamped email, no cleanup needed.
# READ-SAFE: Does not modify any setup state.
#
# Prerequisites:
#   - All prior setup steps (01-05) must be complete
#   - credentials/end-users-org{-dev}.json must exist
#   - credentials/{service}{-dev}.json must exist
#   - jq and curl must be available
#
# Usage:
#   ./scripts/06-test-end-user.sh
#   AUTH_SERVICE_URL=http://localhost:8001 ./scripts/06-test-end-user.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_DIR="${SETUP_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
AUTH_SERVICE_URL="${AUTH_SERVICE_URL:-https://auth.service.ab0t.com}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0
TOTAL_STEPS=5  # bumped to 6 below if org_structure.pattern is workspace-per-user

mark_pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo -e "  ${GREEN}PASS${NC}  $1"; }
mark_fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo -e "  ${RED}FAIL${NC}  $1"; }

# Requirements
for cmd in jq curl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo -e "${RED}ERROR: $cmd is required${NC}"
    exit 1
  fi
done

# Determine environment suffix
if echo "$AUTH_SERVICE_URL" | grep -qE "localhost|dev\.ab0t\.com"; then
  ENV_SUFFIX="-dev"
else
  ENV_SUFFIX=""
fi

# Load configs
PERMISSIONS_FILE="${PERMISSIONS_FILE:-$SETUP_DIR/config/permissions.json}"
SERVICE_ID="$(jq -r '.service.id // "integration"' "$PERMISSIONS_FILE" 2>/dev/null || echo "integration")"

# Read org_structure pattern — adds Step 6 to the test plan when non-flat
WANTED_PATTERN="$(jq -r '.end_users.org_structure.pattern // "flat"' "$PERMISSIONS_FILE" 2>/dev/null || echo "flat")"
if [ "$WANTED_PATTERN" = "workspace-per-user" ]; then
  TOTAL_STEPS=6
fi

# Load end-users org credentials
EU_CREDS="$SETUP_DIR/credentials/end-users-org${ENV_SUFFIX}.json"
if [ ! -f "$EU_CREDS" ] && [ -n "$ENV_SUFFIX" ]; then
  EU_CREDS="$SETUP_DIR/credentials/end-users-org.json"
fi

if [ ! -f "$EU_CREDS" ]; then
  echo -e "${RED}ERROR: End-users org credentials not found. Run steps 01-04 first.${NC}"
  exit 1
fi

EU_ORG_ID="$(jq -r '.org_id' "$EU_CREDS")"
EU_ORG_SLUG="$(jq -r '.org_slug' "$EU_CREDS")"
DEFAULT_TEAM_ID="$(jq -r '.default_team_id // empty' "$EU_CREDS")"
DEFAULT_TEAM_NAME="$(jq -r '.default_team_name // "Default Users"' "$EU_CREDS")"
PERM_MODEL="$(jq -r '.permission_model // "unknown"' "$EU_CREDS")"

# Load service credentials (for admin verification)
SVC_CREDS="$SETUP_DIR/credentials/${SERVICE_ID}${ENV_SUFFIX}.json"
if [ ! -f "$SVC_CREDS" ] && [ -n "$ENV_SUFFIX" ]; then
  SVC_CREDS="$SETUP_DIR/credentials/${SERVICE_ID}.json"
fi

# Generate test user
TS="$(date +%s)"
TEST_EMAIL="setup-test-${TS}@test-setup.example.com"
TEST_PASS="SetupTest_${TS}_Secure1"
TEST_NAME="Setup Test User ${TS}"

echo -e "${CYAN}=== End-User Verification ===${NC}"
echo ""
echo "End-Users Org:    $EU_ORG_SLUG ($EU_ORG_ID)"
echo "Permission Model: $PERM_MODEL"
echo "Default Team:     $DEFAULT_TEAM_NAME (${DEFAULT_TEAM_ID:-none})"
echo "Org Structure:    $WANTED_PATTERN"
echo "Test User:        $TEST_EMAIL"
echo "Auth Service:     $AUTH_SERVICE_URL"
echo ""

# ── Step 1: Register test user via org-scoped endpoint ──
echo -e "${BLUE}Step 1: Register test user via hosted login API${NC}"

REG_PAYLOAD="$(jq -n --arg e "$TEST_EMAIL" --arg p "$TEST_PASS" --arg n "$TEST_NAME" '{email:$e, password:$p, name:$n}')"
REG_RESPONSE="$(curl -s -w "\nHTTP_CODE:%{http_code}" \
  -X POST "$AUTH_SERVICE_URL/organizations/$EU_ORG_SLUG/auth/register" \
  -H "Content-Type: application/json" \
  -d "$REG_PAYLOAD")"

HTTP_CODE="$(echo "$REG_RESPONSE" | grep "HTTP_CODE" | cut -d: -f2)"
REG_BODY="$(echo "$REG_RESPONSE" | grep -v "HTTP_CODE")"

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
  USER_TOKEN="$(echo "$REG_BODY" | jq -r '.access_token // empty')"
  USER_ID="$(echo "$REG_BODY" | jq -r '.user.id // .user_id // empty')"
  if [ -n "$USER_TOKEN" ] && [ "$USER_TOKEN" != "null" ]; then
    mark_pass "User registered and got access token"
    echo "           User ID: $USER_ID"
  else
    mark_fail "Registration returned $HTTP_CODE but no access_token"
    echo "           Response: $REG_BODY"
  fi
else
  mark_fail "Registration failed (HTTP $HTTP_CODE)"
  echo "           Response: $REG_BODY"
  USER_TOKEN=""
fi

# ── Step 2: Verify user is member of end-users org ──
echo -e "${BLUE}Step 2: Verify org membership + active context${NC}"

if [ -n "${USER_TOKEN:-}" ]; then
  ME_RESPONSE="$(curl -s "$AUTH_SERVICE_URL/users/me" \
    -H "Authorization: Bearer $USER_TOKEN")"

  ACTIVE_ORG="$(echo "$ME_RESPONSE" | jq -r '.active_org_id // empty')"
  HAS_EU_ORG="$(echo "$ME_RESPONSE" | jq --arg oid "$EU_ORG_ID" \
    '[.organizations[]? | select(.org_id == $oid)] | length')"

  if [ "${HAS_EU_ORG:-0}" -ge 1 ] && [ "$ACTIVE_ORG" = "$EU_ORG_ID" ]; then
    mark_pass "User is member of end-users org, active context correct"
  elif [ "${HAS_EU_ORG:-0}" -ge 1 ]; then
    mark_fail "User is member but active_org_id = $ACTIVE_ORG (expected $EU_ORG_ID)"
  else
    mark_fail "User is NOT a member of end-users org"
    echo "           Orgs: $(echo "$ME_RESPONSE" | jq -c '[.organizations[]?.org_id]')"
  fi
else
  mark_fail "Cannot verify — registration failed in Step 1"
fi

# ── Step 3: Verify user auto-joined default team ──
echo -e "${BLUE}Step 3: Verify user auto-joined default team${NC}"

if [ -n "${USER_TOKEN:-}" ] && [ -n "${DEFAULT_TEAM_ID:-}" ]; then
  TEAMS_RESPONSE="$(curl -s "$AUTH_SERVICE_URL/organizations/$EU_ORG_ID/teams" \
    -H "Authorization: Bearer $USER_TOKEN" 2>/dev/null || echo "[]")"

  # Check if user is in the default team by querying team members
  TEAM_MEMBERS="$(curl -s "$AUTH_SERVICE_URL/teams/$DEFAULT_TEAM_ID/members" \
    -H "Authorization: Bearer $USER_TOKEN" 2>/dev/null || echo "[]")"

  IN_TEAM="$(echo "$TEAM_MEMBERS" | jq --arg uid "$USER_ID" \
    '[.[]? | select(.user_id == $uid or .id == $uid)] | length' 2>/dev/null || echo "0")"

  if [ "${IN_TEAM:-0}" -ge 1 ]; then
    mark_pass "User auto-joined '$DEFAULT_TEAM_NAME' team"
  else
    # Fallback: check via /users/me teams if available
    MY_TEAMS="$(echo "$ME_RESPONSE" | jq --arg tid "$DEFAULT_TEAM_ID" \
      '[.teams[]? | select(.team_id == $tid or .id == $tid)] | length' 2>/dev/null || echo "0")"
    if [ "${MY_TEAMS:-0}" -ge 1 ]; then
      mark_pass "User auto-joined '$DEFAULT_TEAM_NAME' team (via /users/me)"
    else
      mark_fail "User NOT in default team '$DEFAULT_TEAM_NAME' ($DEFAULT_TEAM_ID)"
      echo "           Team members response: $(echo "$TEAM_MEMBERS" | jq -c '.' 2>/dev/null || echo "$TEAM_MEMBERS")"
    fi
  fi
elif [ -z "${DEFAULT_TEAM_ID:-}" ]; then
  mark_fail "No default_team_id in credentials — step 04 may not have set it"
else
  mark_fail "Cannot verify — registration failed in Step 1"
fi

# ── Step 4: Verify user has default_grant permissions ──
echo -e "${BLUE}Step 4: Verify user has default_grant permissions${NC}"

if [ -n "${USER_TOKEN:-}" ]; then
  DEFAULT_PERMS="$(jq -r '.permissions[] | select(.default_grant == true) | .id' "$PERMISSIONS_FILE")"
  PERM_TOTAL="$(echo "$DEFAULT_PERMS" | grep -c . || true)"
  PERM_OK=0
  PERM_MISSING=""

  # Get user's permissions from the auth service
  USER_PERMS="$(curl -s "$AUTH_SERVICE_URL/permissions/user/$USER_ID?org_id=$EU_ORG_ID" \
    -H "Authorization: Bearer $USER_TOKEN" 2>/dev/null || echo "{}")"

  for PERM in $DEFAULT_PERMS; do
    # Check if permission exists in the response (.permissions[] array or flat array)
    HAS="$(echo "$USER_PERMS" | jq --arg p "$PERM" \
      '[(.permissions[]? // .[]?) | select(. == $p)] | length' 2>/dev/null || echo "0")"
    if [ "${HAS:-0}" -ge 1 ]; then
      PERM_OK=$((PERM_OK + 1))
    else
      PERM_MISSING="${PERM_MISSING}${PERM}, "
    fi
  done

  if [ "$PERM_OK" -eq "$PERM_TOTAL" ]; then
    mark_pass "User has all $PERM_TOTAL default_grant permissions"
  elif [ "$PERM_OK" -gt 0 ]; then
    mark_fail "User has $PERM_OK/$PERM_TOTAL permissions — missing: ${PERM_MISSING%, }"
  else
    mark_fail "User has 0/$PERM_TOTAL default_grant permissions"
    echo "           Permissions response: $(echo "$USER_PERMS" | jq -c '.[0:3]' 2>/dev/null || echo "$USER_PERMS" | head -c 200)"
  fi
else
  mark_fail "Cannot verify — registration failed in Step 1"
fi

# ── Step 5: Verify user does NOT have admin permissions ──
echo -e "${BLUE}Step 5: Verify user does NOT have admin/critical permissions${NC}"

if [ -n "${USER_TOKEN:-}" ]; then
  ADMIN_PERMS="$(jq -r '.permissions[] | select(.default_grant == false) | .id' "$PERMISSIONS_FILE")"
  LEAK_COUNT=0
  LEAKED=""

  for PERM in $ADMIN_PERMS; do
    HAS="$(echo "$USER_PERMS" | jq --arg p "$PERM" \
      '[(.permissions[]? // .[]?) | select(. == $p)] | length' 2>/dev/null || echo "0")"
    if [ "${HAS:-0}" -ge 1 ]; then
      LEAK_COUNT=$((LEAK_COUNT + 1))
      LEAKED="${LEAKED}${PERM}, "
    fi
  done

  if [ "$LEAK_COUNT" -eq 0 ]; then
    mark_pass "User correctly denied admin/critical permissions"
  else
    mark_fail "SECURITY: User has $LEAK_COUNT admin permissions that should be denied: ${LEAKED%, }"
  fi
else
  mark_fail "Cannot verify — registration failed in Step 1"
fi

# ── Step 6: Verify workspace materialized (only when workspace-per-user) ──
# The auth service runs an in-process event handler that subscribes to
# auth.user.registered and creates a private nested org for the user
# when login_config.registration.org_structure.pattern is workspace-per-user.
# This step asserts that handler actually ran and produced the workspace.
#
# Skipped silently for pattern flat — no workspace expected.
if [ "$WANTED_PATTERN" = "workspace-per-user" ]; then
  echo -e "${BLUE}Step 6: Verify workspace materialized for user${NC}"

  if [ -z "${USER_TOKEN:-}" ]; then
    mark_fail "Cannot verify — registration failed in Step 1"
  elif [ -z "${USER_ID:-}" ]; then
    mark_fail "Cannot verify — no USER_ID extracted from registration response"
  else
    # Brief wait for handler to complete (it runs async after the registration event fires)
    sleep 2

    # Query the end-users org hierarchy (user has org.read via member role on the parent)
    HIERARCHY="$(curl -s --max-time 5 \
      "$AUTH_SERVICE_URL/organizations/$EU_ORG_ID/hierarchy" \
      -H "Authorization: Bearer $USER_TOKEN" 2>/dev/null || echo "{}")"

    # Find a child where settings tags this as a user_workspace owned by our test user
    WORKSPACE_ID="$(echo "$HIERARCHY" | jq -r --arg uid "$USER_ID" \
      '[.children[]?, .child_organizations[]? | select(.settings.type == "user_workspace" and .settings.owner_user_id == $uid)] | .[0].id // empty' \
      2>/dev/null)"

    if [ -n "$WORKSPACE_ID" ] && [ "$WORKSPACE_ID" != "null" ]; then
      WORKSPACE_SLUG="$(echo "$HIERARCHY" | jq -r --arg id "$WORKSPACE_ID" \
        '[.children[]?, .child_organizations[]? | select(.id == $id)] | .[0].slug // empty' 2>/dev/null)"
      mark_pass "Workspace materialized: ${WORKSPACE_SLUG:-(slug unknown)} ($WORKSPACE_ID)"
    else
      mark_fail "Workspace NOT materialized for $USER_ID — auth handler may have failed"
      echo -e "  ${YELLOW}→ Check auth service logs for 'workspace_handler_failed' on user_id=$USER_ID${NC}"
      echo -e "  ${YELLOW}→ Run './setup verify' to confirm org_structure pattern is in login_config${NC}"
      echo -e "  ${YELLOW}→ Confirm appv2/event_handlers/workspace_provisioning.py registered at startup${NC}"
    fi
  fi
fi

# ── Summary ──
echo ""
echo -e "${CYAN}=== End-User Verification Summary ===${NC}"
echo ""
echo -e "  Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed (of ${TOTAL_STEPS})"
echo ""

if [ "$FAIL_COUNT" -eq 0 ]; then
  echo -e "${GREEN}  VERDICT: The setup works end-to-end.${NC}"
  echo ""
  echo "  A new user registered at:"
  echo "    $AUTH_SERVICE_URL/login/$EU_ORG_SLUG"
  echo ""
  echo "  They auto-joined the '$DEFAULT_TEAM_NAME' team and received"
  echo "  all $PERM_TOTAL default permissions. Admin permissions are denied."
  echo ""
  echo "  Your frontend login URL:"
  echo -e "    ${GREEN}$AUTH_SERVICE_URL/login/$EU_ORG_SLUG${NC}"
else
  echo -e "${RED}  VERDICT: ${FAIL_COUNT} checks failed — see above for details.${NC}"
  echo ""
  echo "  Common fixes:"
  echo "  - Step 1 fail: Check signup_enabled in hosted-login.json"
  echo "  - Step 3 fail: Check default_team in login config (run step 04)"
  echo "  - Step 4 fail: Check team permissions (re-run step 04)"
  echo "  - Step 5 fail: SECURITY — review permission grants immediately"
fi

exit "$FAIL_COUNT"
