#!/bin/bash
# Verify that the full Auth Mesh setup is working correctly.
#
# This script:
#   1. Checks all config files exist and are valid
#   2. Checks all credentials files were generated
#   3. Tests auth service connectivity
#   4. Verifies hosted login page is accessible
#   5. Verifies org hierarchy (end-users org is child of service org)
#   6. Reports overall status
#
# Usage:
#   ./scripts/05-verify-setup.sh
#   AUTH_SERVICE_URL=https://auth.dev.ab0t.com ./scripts/05-verify-setup.sh

set -euo pipefail

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

PASS=0
FAIL=0
WARN=0

pass() { echo -e "  ${GREEN}PASS${NC}  $1"; PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}FAIL${NC}  $1"; FAIL=$((FAIL + 1)); }
warn() { echo -e "  ${YELLOW}WARN${NC}  $1"; WARN=$((WARN + 1)); }
info() { echo -e "  ${BLUE}INFO${NC}  $1"; }

echo -e "${CYAN}=== Auth Mesh Setup Verification ===${NC}"
echo ""

# ── Section 1: Prerequisites ──
echo -e "${BLUE}Prerequisites${NC}"

for cmd in jq curl python3; do
  if command -v "$cmd" >/dev/null 2>&1; then
    pass "$cmd installed"
  else
    fail "$cmd not found"
  fi
done

# ── Section 2: Config files ──
echo ""
echo -e "${BLUE}Config Files${NC}"

PERMISSIONS_FILE="$SETUP_DIR/config/permissions.json"
OAUTH_CLIENT_FILE="$SETUP_DIR/config/oauth-client.json"
HOSTED_LOGIN_FILE="$SETUP_DIR/config/hosted-login.json"

for f in "$PERMISSIONS_FILE" "$OAUTH_CLIENT_FILE" "$HOSTED_LOGIN_FILE"; do
  FNAME="config/$(basename "$f")"
  if [ -f "$f" ]; then
    if jq . "$f" >/dev/null 2>&1; then
      pass "$FNAME valid JSON"
    else
      fail "$FNAME invalid JSON"
    fi
  else
    fail "$FNAME not found"
  fi
done

# Check permissions.json key fields
if [ -f "$PERMISSIONS_FILE" ]; then
  SVC_ID="$(jq -r '.service.id // empty' "$PERMISSIONS_FILE")"
  PERM_COUNT="$(jq '.permissions | length' "$PERMISSIONS_FILE")"
  DEFAULT_COUNT="$(jq '[.permissions[] | select(.default_grant == true)] | length' "$PERMISSIONS_FILE")"
  ROLE_COUNT="$(jq '.roles | length' "$PERMISSIONS_FILE")"

  if [ -n "$SVC_ID" ]; then
    pass "service.id = $SVC_ID"
  else
    fail "service.id missing in permissions.json"
  fi
  info "$PERM_COUNT permissions, $DEFAULT_COUNT default_grant, $ROLE_COUNT roles"
fi

# ── Section 3: Credentials ──
echo ""
echo -e "${BLUE}Credentials${NC}"

# Determine env suffix
if echo "$AUTH_SERVICE_URL" | grep -qE "localhost|dev\.ab0t\.com"; then
  ENV_SUFFIX="-dev"
else
  ENV_SUFFIX=""
fi

SVC_ID="$(jq -r '.service.id // "integration"' "$PERMISSIONS_FILE" 2>/dev/null || echo "integration")"

# Service credentials
SVC_CREDS="$SETUP_DIR/credentials/${SVC_ID}${ENV_SUFFIX}.json"
if [ ! -f "$SVC_CREDS" ] && [ -n "$ENV_SUFFIX" ]; then
  SVC_CREDS="$SETUP_DIR/credentials/${SVC_ID}.json"
fi
if [ ! -f "$SVC_CREDS" ]; then
  SVC_CREDS="$SETUP_DIR/credentials/integration-service.json"
fi

if [ -f "$SVC_CREDS" ]; then
  pass "Service credentials: $(basename "$SVC_CREDS")"
  ORG_ID="$(jq -r '.organization.id // empty' "$SVC_CREDS")"
  ORG_SLUG="$(jq -r '.organization.slug // empty' "$SVC_CREDS")"
  API_KEY="$(jq -r '.api_key.key // empty' "$SVC_CREDS")"

  if [ -n "$ORG_ID" ]; then pass "Service org_id present"; else fail "org_id missing"; fi
  if [ -n "$API_KEY" ]; then pass "API key present"; else warn "API key missing"; fi
else
  fail "Service credentials not found (run step 01)"
  ORG_ID=""
  ORG_SLUG=""
fi

# OAuth client
OAUTH_CREDS="$SETUP_DIR/credentials/oauth-client${ENV_SUFFIX}.json"
if [ ! -f "$OAUTH_CREDS" ] && [ -n "$ENV_SUFFIX" ]; then
  OAUTH_CREDS="$SETUP_DIR/credentials/oauth-client.json"
fi

if [ -f "$OAUTH_CREDS" ]; then
  CLIENT_ID="$(jq -r '.client_id // empty' "$OAUTH_CREDS")"
  if [ -n "$CLIENT_ID" ]; then
    pass "OAuth client: $CLIENT_ID"
  else
    fail "OAuth client file exists but client_id missing"
  fi
else
  warn "OAuth client not registered (run step 02)"
fi

# Hosted login
HL_CREDS="$SETUP_DIR/credentials/hosted-login${ENV_SUFFIX}.json"
if [ ! -f "$HL_CREDS" ] && [ -n "$ENV_SUFFIX" ]; then
  HL_CREDS="$SETUP_DIR/credentials/hosted-login.json"
fi

if [ -f "$HL_CREDS" ]; then
  pass "Hosted login configured"
else
  warn "Hosted login not configured (run step 03)"
fi

# End-users org
EU_CREDS="$SETUP_DIR/credentials/end-users-org${ENV_SUFFIX}.json"
if [ ! -f "$EU_CREDS" ] && [ -n "$ENV_SUFFIX" ]; then
  EU_CREDS="$SETUP_DIR/credentials/end-users-org.json"
fi

EU_SLUG=""
if [ -f "$EU_CREDS" ]; then
  EU_ORG_ID="$(jq -r '.org_id // empty' "$EU_CREDS")"
  EU_SLUG="$(jq -r '.org_slug // empty' "$EU_CREDS")"
  EU_PARENT="$(jq -r '.parent_org_id // empty' "$EU_CREDS")"
  EU_ROLE="$(jq -r '.default_role // empty' "$EU_CREDS")"
  EU_PERM_MODEL="$(jq -r '.permission_model // empty' "$EU_CREDS")"

  if [ -n "$EU_ORG_ID" ]; then
    pass "End-users org: $EU_SLUG ($EU_ORG_ID)"
  else
    fail "End-users org file exists but org_id missing"
  fi

  if [ -n "$EU_PARENT" ] && [ "$EU_PARENT" = "$ORG_ID" ]; then
    pass "Parent hierarchy: end-users -> service org"
  elif [ -n "$EU_PARENT" ]; then
    warn "Parent org ($EU_PARENT) does not match service org ($ORG_ID)"
  fi

  if [ "$EU_ROLE" = "member" ]; then
    pass "Default role: member (correct)"
  elif [ "$EU_ROLE" = "end_user" ]; then
    fail "Default role: end_user (should be member)"
  fi

  if [ "$EU_PERM_MODEL" = "org-inherited" ]; then
    pass "Permission model: org-inherited"
  fi
else
  warn "End-users org not created (run step 04)"
fi

# ── Section 4: Auth Service Connectivity ──
echo ""
echo -e "${BLUE}Auth Service Connectivity${NC}"

HEALTH_CODE="$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$AUTH_SERVICE_URL/health" 2>/dev/null || echo "000")"
if [ "$HEALTH_CODE" = "200" ]; then
  pass "Auth service healthy: $AUTH_SERVICE_URL"
else
  fail "Auth service unreachable (HTTP $HEALTH_CODE)"
fi

# ── Section 5: Hosted Login ──
echo ""
echo -e "${BLUE}Hosted Login Endpoints${NC}"

LOGIN_SLUG="${EU_SLUG:-$ORG_SLUG}"
if [ -n "$LOGIN_SLUG" ]; then
  LOGIN_CODE="$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$AUTH_SERVICE_URL/login/$LOGIN_SLUG" 2>/dev/null || echo "000")"
  if [ "$LOGIN_CODE" = "200" ]; then
    pass "Login page: $AUTH_SERVICE_URL/login/$LOGIN_SLUG"
  else
    warn "Login page returned HTTP $LOGIN_CODE"
  fi

  PUBLIC_CODE="$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
    "$AUTH_SERVICE_URL/organizations/$LOGIN_SLUG/login-config/public" 2>/dev/null || echo "000")"
  if [ "$PUBLIC_CODE" = "200" ]; then
    pass "Public config endpoint accessible"
  else
    warn "Public config returned HTTP $PUBLIC_CODE"
  fi

  PROVIDERS_CODE="$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
    "$AUTH_SERVICE_URL/organizations/$LOGIN_SLUG/auth/providers" 2>/dev/null || echo "000")"
  if [ "$PROVIDERS_CODE" = "200" ]; then
    pass "Auth providers endpoint accessible"
  else
    warn "Auth providers returned HTTP $PROVIDERS_CODE"
  fi
else
  warn "No org slug available, skipping endpoint checks"
fi

# ── Section 6: Admin Login ──
echo ""
echo -e "${BLUE}Admin Access${NC}"

if [ -n "$ORG_ID" ] && [ -f "$SVC_CREDS" ]; then
  TOKEN="$(python3 << PYEOF 2>/dev/null || true
import json, urllib.request, ssl, sys
creds = json.load(open("$SVC_CREDS"))
data = json.dumps({
    "email": creds["admin"]["email"],
    "password": creds["admin"]["password"],
    "org_id": creds["organization"]["id"]
}).encode()
req = urllib.request.Request(
    "$AUTH_SERVICE_URL/auth/login",
    data=data, headers={"Content-Type": "application/json"}
)
try:
    resp = urllib.request.urlopen(req, context=ssl.create_default_context())
    print(json.loads(resp.read())["access_token"])
except:
    pass
PYEOF
)"

  if [ -n "$TOKEN" ]; then
    pass "Admin login successful"

    MEMBERS_RESPONSE="$(curl -s "$AUTH_SERVICE_URL/organizations/$ORG_ID/users" \
      -H "Authorization: Bearer $TOKEN" 2>/dev/null || echo "[]")"
    MEMBER_COUNT="$(echo "$MEMBERS_RESPONSE" | jq 'length' 2>/dev/null || echo "0")"
    pass "Service org: $MEMBER_COUNT members"
  else
    warn "Admin login failed, skipping live checks"
  fi
else
  warn "No credentials available, skipping live checks"
fi

# ── Section 7: Org Structure ──
# Verify that the org_structure pattern declared in permissions.json was
# actually written to the end-users org's login_config. Catches the
# "silent disable via typo" failure mode where someone edited
# permissions.json but forgot to re-run script 04.
#
# Skipped for pattern "flat" (the safe default — no verification noise
# for clients who didn't opt in to org structures).
echo ""
echo -e "${BLUE}Org Structure${NC}"

DESIRED_PATTERN="$(jq -r '.end_users.org_structure.pattern // "flat"' "$PERMISSIONS_FILE" 2>/dev/null || echo "flat")"

if [ "$DESIRED_PATTERN" = "flat" ]; then
  pass "Pattern: flat (no extra orgs created on signup — existing behavior)"
elif [ -z "${TOKEN:-}" ]; then
  warn "Org structure '$DESIRED_PATTERN' configured but admin token unavailable, skipping live verification"
elif [ -z "${EU_ORG_ID:-}" ]; then
  warn "Org structure '$DESIRED_PATTERN' configured but end-users org ID not found in credentials, skipping live verification"
else
  # Fetch the live login_config (authenticated — needed because org_structure
  # lives under .registration which is excluded from /login-config/public).
  LIVE_CONFIG="$(curl -s --max-time 5 \
    "$AUTH_SERVICE_URL/organizations/$EU_ORG_ID/login-config" \
    -H "Authorization: Bearer $TOKEN" 2>/dev/null || echo "{}")"

  LIVE_PATTERN="$(echo "$LIVE_CONFIG" | jq -r '.registration.org_structure.pattern // "flat"' 2>/dev/null || echo "flat")"

  if [ "$LIVE_PATTERN" = "$DESIRED_PATTERN" ]; then
    pass "Pattern: $DESIRED_PATTERN (configured in permissions.json AND live in login_config)"

    # If non-flat, also surface the config block for visibility
    if [ "$DESIRED_PATTERN" != "flat" ]; then
      LIVE_CONFIG_BLOCK="$(echo "$LIVE_CONFIG" | jq -c '.registration.org_structure.config' 2>/dev/null || echo "{}")"
      pass "Config: $LIVE_CONFIG_BLOCK"
    fi
  else
    fail "Org structure mismatch: permissions.json wants '$DESIRED_PATTERN' but login_config has '$LIVE_PATTERN'"
    echo -e "  ${YELLOW}→ Run './setup run 04' to re-apply the configured org_structure${NC}"
  fi
fi

# ── Summary ──
echo ""
echo -e "${CYAN}=== Verification Summary ===${NC}"
echo ""
echo -e "  ${GREEN}PASS: $PASS${NC}"
[ "$WARN" -gt 0 ] && echo -e "  ${YELLOW}WARN: $WARN${NC}"
[ "$FAIL" -gt 0 ] && echo -e "  ${RED}FAIL: $FAIL${NC}"
echo ""

if [ "$FAIL" -gt 0 ]; then
  echo -e "${RED}Setup has failures. Run the numbered scripts in order to fix.${NC}"
  exit 1
elif [ "$WARN" -gt 0 ]; then
  echo -e "${YELLOW}Setup is partial. Some optional steps haven't been run yet.${NC}"
  exit 0
else
  echo -e "${GREEN}Setup is complete and verified.${NC}"
  exit 0
fi
