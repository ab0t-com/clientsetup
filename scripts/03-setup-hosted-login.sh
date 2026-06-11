#!/bin/bash
# Setup hosted login configuration for an organization.
#
# This script:
#   1. Reads login config from config/hosted-login.json (branding, auth methods, etc.)
#   2. Reads service credentials (who to auth as)
#   3. PUTs the login config to the auth service
#   4. Verifies the hosted login page and endpoints are accessible
#   5. Saves the result to credentials/hosted-login.json (or hosted-login-dev.json)
#
# IDEMPOTENT: PUT replaces the entire login config. Safe to run multiple times.
#
# Prerequisites:
#   - config/hosted-login.json must exist
#   - credentials/{service}.json must exist (from 01-register-service-permissions.sh)
#   - jq and python3 must be available
#
# Usage:
#   ./scripts/03-setup-hosted-login.sh
#   AUTH_SERVICE_URL=https://auth.dev.ab0t.com ./scripts/03-setup-hosted-login.sh
#   DRY_RUN=1 ./scripts/03-setup-hosted-login.sh

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

# Load login config
LOGIN_CONFIG="${LOGIN_CONFIG:-$SETUP_DIR/config/hosted-login.json}"
if [ ! -f "$LOGIN_CONFIG" ]; then
  echo -e "${RED}ERROR: $LOGIN_CONFIG not found.${NC}"
  echo "Create config/hosted-login.json with: branding, content, auth_methods, registration, security"
  exit 1
fi

# Validate it's valid JSON
jq . "$LOGIN_CONFIG" >/dev/null 2>&1 || {
  echo -e "${RED}ERROR: $LOGIN_CONFIG is not valid JSON${NC}"
  exit 1
}

# Determine environment suffix from auth service URL
if echo "$AUTH_SERVICE_URL" | grep -qE "localhost|dev\.ab0t\.com"; then
  ENV_SUFFIX="-dev"
else
  ENV_SUFFIX=""
fi

# Load service credentials
PERMISSIONS_FILE="${PERMISSIONS_FILE:-$SETUP_DIR/config/permissions.json}"
SERVICE_ID="${SERVICE_ID:-$(jq -r '.service.id // "integration"' "$PERMISSIONS_FILE" 2>/dev/null || echo "integration")}"
CREDS_FILE="$SETUP_DIR/credentials/${SERVICE_ID}${ENV_SUFFIX}.json"

# Fallback: try without suffix if env-specific file doesn't exist
if [ ! -f "$CREDS_FILE" ] && [ -n "$ENV_SUFFIX" ]; then
  FALLBACK="$SETUP_DIR/credentials/${SERVICE_ID}.json"
  if [ -f "$FALLBACK" ]; then
    echo -e "${YELLOW}No ${SERVICE_ID}${ENV_SUFFIX}.json found, using ${SERVICE_ID}.json${NC}"
    CREDS_FILE="$FALLBACK"
  fi
fi

if [ ! -f "$CREDS_FILE" ]; then
  echo -e "${RED}ERROR: $CREDS_FILE not found. Run 01-register-service-permissions.sh first.${NC}"
  exit 1
fi

ORG_ID="$(jq -r '.organization.id' "$CREDS_FILE")"
ORG_SLUG="$(jq -r '.organization.slug // .service' "$CREDS_FILE")"

if [ -z "$ORG_ID" ] || [ "$ORG_ID" = "null" ]; then
  echo -e "${RED}ERROR: organization.id missing in $CREDS_FILE${NC}"
  exit 1
fi

OUTPUT_FILE="$SETUP_DIR/credentials/hosted-login${ENV_SUFFIX}.json"

echo -e "${CYAN}=== Hosted Login Setup ===${NC}"
echo ""
echo "Config:         $LOGIN_CONFIG"
echo "Credentials:    $CREDS_FILE"
echo "Auth Service:   $AUTH_SERVICE_URL"
echo "Org:            $ORG_SLUG ($ORG_ID)"
echo "Output:         $OUTPUT_FILE"
echo ""

LOGIN_CONFIG_PAYLOAD="$(cat "$LOGIN_CONFIG")"

# ──────────────────────────────────────────────────────────────
# Smart default: accept_invite_allowed_origins
# ──────────────────────────────────────────────────────────────
# If the customer left security.accept_invite_allowed_origins empty (or
# missing), derive it from the OAuth client's redirect_uris. Those
# origins are already trusted for OAuth callbacks — using them as the
# invite-landing allowlist mirrors that trust boundary and removes a
# duplicated-config foot-gun.
#
# We DO NOT smart-default accept_invite_url / accept_invite_error_url —
# those are customer-specific UX decisions and a wrong default would
# silently send invitees somewhere unexpected. Empty values for those
# trigger the bundled fallback page on the auth service.
#
# Only runs when oauth-client.json exists (the consumer of step 02) AND
# the user-provided config has no allowlist values.
OAUTH_CLIENT_CONFIG="${OAUTH_CLIENT_CONFIG:-$SETUP_DIR/config/oauth-client.json}"
HAS_ALLOWLIST="$(echo "$LOGIN_CONFIG_PAYLOAD" \
  | jq -r '(.security.accept_invite_allowed_origins // []) | length' 2>/dev/null || echo 0)"
if [ "$HAS_ALLOWLIST" = "0" ] && [ -f "$OAUTH_CLIENT_CONFIG" ]; then
  # Extract unique origins (scheme + netloc) from redirect_uris.
  # `try ... catch empty` skips entries that don't match the regex (no
  # scheme, malformed) instead of aborting the whole map under set -e.
  # Outer `|| echo '[]'` is a belt-and-braces fallback for any other
  # jq failure (file unreadable, malformed JSON we somehow missed).
  DERIVED_ORIGINS="$(jq -r '
    (.redirect_uris // [])
    | map(try (capture("^(?<o>[^/]+//[^/]+)") | .o) catch empty)
    | unique
  ' "$OAUTH_CLIENT_CONFIG" 2>/dev/null || echo '[]')"
  DERIVED_COUNT="$(echo "$DERIVED_ORIGINS" | jq -r 'length' 2>/dev/null || echo 0)"
  if [ "$DERIVED_COUNT" -gt 0 ] 2>/dev/null; then
    echo -e "${YELLOW}Smart default: filling security.accept_invite_allowed_origins from oauth-client.json${NC}"
    echo "  Derived $DERIVED_COUNT origin(s) from redirect_uris:"
    echo "$DERIVED_ORIGINS" | jq -r '.[]' | sed 's/^/    /'
    LOGIN_CONFIG_PAYLOAD="$(echo "$LOGIN_CONFIG_PAYLOAD" \
      | jq --argjson o "$DERIVED_ORIGINS" \
        '.security.accept_invite_allowed_origins = $o' \
      || echo "$LOGIN_CONFIG_PAYLOAD")"
  fi
fi

# Coach: if accept_invite_url is unset, the auth service's /accept-invite
# endpoint falls back to a bundled generic landing page. That's safe but
# silent — surface the choice once at setup time so the customer knows
# their invitees aren't getting a branded experience.
ACCEPT_URL_VALUE="$(echo "$LOGIN_CONFIG_PAYLOAD" | jq -r '.security.accept_invite_url // ""' 2>/dev/null || echo "")"
if [ -z "$ACCEPT_URL_VALUE" ] || [ "$ACCEPT_URL_VALUE" = "null" ]; then
  echo -e "${BLUE}INFO:${NC} security.accept_invite_url is unset."
  echo "       Invitation links will land on the auth service's bundled fallback page."
  echo "       Set accept_invite_url in $LOGIN_CONFIG to point at your app's"
  echo "       invitation-acceptance route for a branded experience."
fi

# Cross-field check: warn (don't fail) if accept_invite_url or
# accept_invite_error_url are configured but the resolved allowlist
# doesn't cover them. The auth service will reject the PUT in that
# case anyway with HTTP 400 — pre-flight here gives a friendlier
# error pointing at the right line.
for FIELD in accept_invite_url accept_invite_error_url; do
  URL="$(echo "$LOGIN_CONFIG_PAYLOAD" | jq -r ".security.${FIELD} // \"\"")"
  if [ -z "$URL" ] || [ "$URL" = "null" ]; then continue; fi
  URL_ORIGIN="$(printf '%s' "$URL" | sed -nE 's|^([^/]+//[^/]+).*$|\1|p')"
  # Malformed URL (no scheme://) → skip silently. validate-config.sh
  # has a dedicated "not a valid URL" warning that's the right place
  # to surface this; printing "'' is not in allowlist" here would be
  # confusing (the user's mistake is the URL, not the allowlist).
  if [ -z "$URL_ORIGIN" ]; then continue; fi
  IN_LIST="$(echo "$LOGIN_CONFIG_PAYLOAD" \
    | jq -r --arg o "$URL_ORIGIN" \
      '(.security.accept_invite_allowed_origins // []) | map(ascii_downcase) | index($o | ascii_downcase) // "no"')"
  if [ "$IN_LIST" = "no" ]; then
    echo -e "${YELLOW}WARNING:${NC} security.${FIELD} origin '$URL_ORIGIN' is not in security.accept_invite_allowed_origins"
    echo "         The auth service will reject this PUT with HTTP 400."
    echo "         Add '$URL_ORIGIN' to security.accept_invite_allowed_origins in $LOGIN_CONFIG"
  fi
done

if [ "$DRY_RUN" = "1" ]; then
  echo -e "${YELLOW}=== DRY RUN ===${NC}"
  echo "Would PUT to: $AUTH_SERVICE_URL/organizations/$ORG_ID/login-config"
  echo "$LOGIN_CONFIG_PAYLOAD" | jq .
  echo -e "${YELLOW}=== DRY RUN COMPLETE ===${NC}"
  exit 0
fi

# Step 1: Login
echo -e "${BLUE}Step 1: Logging in as org admin${NC}"

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

# Step 2: PUT login config
echo -e "${BLUE}Step 2: Applying login config${NC}"

CONFIG_RESPONSE="$(curl -s -w "\nHTTP_CODE:%{http_code}" \
  -X PUT "$AUTH_SERVICE_URL/organizations/$ORG_ID/login-config" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$LOGIN_CONFIG_PAYLOAD")"

HTTP_CODE="$(echo "$CONFIG_RESPONSE" | grep "HTTP_CODE" | cut -d: -f2)"
RESPONSE_BODY="$(echo "$CONFIG_RESPONSE" | grep -v "HTTP_CODE")"

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
  echo -e "${GREEN}Login config saved${NC}"
else
  echo -e "${RED}Failed to save login config (HTTP $HTTP_CODE)${NC}"
  echo "$RESPONSE_BODY" | jq . 2>/dev/null || echo "$RESPONSE_BODY"
  exit 1
fi

# Step 3: Verify hosted login page
echo -e "${BLUE}Step 3: Verifying hosted login page${NC}"

HOSTED_CODE="$(curl -s -o /dev/null -w "%{http_code}" "$AUTH_SERVICE_URL/login/$ORG_SLUG")"
if [ "$HOSTED_CODE" = "200" ]; then
  echo -e "${GREEN}Hosted login page OK: $AUTH_SERVICE_URL/login/$ORG_SLUG${NC}"
else
  echo -e "${YELLOW}Hosted login page returned HTTP $HOSTED_CODE${NC}"
fi

# Step 4: Verify public config endpoint
echo -e "${BLUE}Step 4: Verifying public config endpoint${NC}"

PUBLIC_RESPONSE="$(curl -s "$AUTH_SERVICE_URL/organizations/$ORG_SLUG/login-config/public")"
PUBLIC_CODE="$(curl -s -o /dev/null -w "%{http_code}" "$AUTH_SERVICE_URL/organizations/$ORG_SLUG/login-config/public")"
if [ "$PUBLIC_CODE" = "200" ]; then
  echo -e "${GREEN}Public config endpoint OK${NC}"
else
  echo -e "${YELLOW}Public config returned HTTP $PUBLIC_CODE${NC}"
fi

# Step 5: Verify org-scoped auth endpoints
echo -e "${BLUE}Step 5: Verifying org auth endpoints${NC}"

PROVIDERS_CODE="$(curl -s -o /dev/null -w "%{http_code}" "$AUTH_SERVICE_URL/organizations/$ORG_SLUG/auth/providers")"
if [ "$PROVIDERS_CODE" = "200" ]; then
  echo -e "${GREEN}Org auth providers endpoint OK${NC}"
else
  echo -e "${YELLOW}Org auth providers returned HTTP $PROVIDERS_CODE${NC}"
fi

# Step 6: Save result
echo -e "${BLUE}Step 6: Saving result${NC}"

# Preserve every JSON response from this run so callers can verify what
# the server actually accepted/normalized (instead of relying on the
# input we sent). See SUGGESTIONS.md for rationale.
_safe_json() {
  printf '%s' "${1:-}" | jq -e . >/dev/null 2>&1 && printf '%s' "$1" || printf '{}'
}

RAW_PUT_LOGIN_CONFIG="$(_safe_json "${RESPONSE_BODY:-}")"
RAW_PUBLIC_CONFIG="$(_safe_json "${PUBLIC_RESPONSE:-}")"

mkdir -p "$SETUP_DIR/credentials"
jq -n \
  --arg org_id "$ORG_ID" \
  --arg org_slug "$ORG_SLUG" \
  --arg url "$AUTH_SERVICE_URL" \
  --arg login_url "$AUTH_SERVICE_URL/login/$ORG_SLUG" \
  --arg public_config_url "$AUTH_SERVICE_URL/organizations/$ORG_SLUG/login-config/public" \
  --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg config "$LOGIN_CONFIG" \
  --argjson applied "$LOGIN_CONFIG_PAYLOAD" \
  --argjson raw_put_login_config "$RAW_PUT_LOGIN_CONFIG" \
  --argjson raw_public_config "$RAW_PUBLIC_CONFIG" \
  --argjson verification "{
    \"hosted_login_page\": $HOSTED_CODE,
    \"public_config\": $PUBLIC_CODE,
    \"auth_providers\": $PROVIDERS_CODE
  }" \
  '{
    org_id: $org_id,
    org_slug: $org_slug,
    hosted_login_url: $login_url,
    public_config_url: $public_config_url,
    applied_config: $applied,
    verification: $verification,
    _meta: {
      auth_service_url: $url,
      source_config: $config,
      applied_at: $date
    },
    _raw: {
      put_login_config: $raw_put_login_config,
      public_config: $raw_public_config
    }
  }' > "$OUTPUT_FILE"

chmod 600 "$OUTPUT_FILE" 2>/dev/null || true
echo -e "${GREEN}Saved to: $OUTPUT_FILE${NC}"

echo ""
echo -e "${CYAN}=== Setup Complete ===${NC}"
echo ""
echo "Hosted login page:  $AUTH_SERVICE_URL/login/$ORG_SLUG"
echo "Public config:      $AUTH_SERVICE_URL/organizations/$ORG_SLUG/login-config/public"
echo "Org login API:      $AUTH_SERVICE_URL/organizations/$ORG_SLUG/auth/login"
echo "Org register API:   $AUTH_SERVICE_URL/organizations/$ORG_SLUG/auth/register"
echo "Org refresh API:    $AUTH_SERVICE_URL/organizations/$ORG_SLUG/auth/refresh"
echo "Org token API:      $AUTH_SERVICE_URL/organizations/$ORG_SLUG/auth/token"
echo ""
echo "Frontend env-config.js should use:"
echo "  window.__INTEGRATION_ORG_SLUG = '$ORG_SLUG';"
echo ""
echo "Integration service .env should have:"
echo "  AB0T_AUTH_AUDIENCE=LOCAL:$ORG_ID"
echo ""
