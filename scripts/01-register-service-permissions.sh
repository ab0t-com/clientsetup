#!/bin/bash
# Canonical service registration for Auth Mesh clients.
# Reads config/permissions.json (schema v2) and performs idempotent registration.
#
# Run from setup/ directory:  ./scripts/01-register-service-permissions.sh
# Or set SETUP_DIR:           SETUP_DIR=/path/to/setup ./scripts/01-register-service-permissions.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_DIR="${SETUP_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
PERMISSIONS_FILE="${PERMISSIONS_FILE:-$SETUP_DIR/config/permissions.json}"
AUTH_SERVICE_URL="${AUTH_SERVICE_URL:-https://auth.service.ab0t.com}"
SERVICE_PORT="${SERVICE_PORT:-8009}"
REGISTER_PROXY="${REGISTER_PROXY:-0}"
DRY_RUN="${DRY_RUN:-0}"

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required"
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "ERROR: curl is required"
  exit 1
fi

if [ ! -f "$PERMISSIONS_FILE" ]; then
  echo "ERROR: .permissions.json not found at $PERMISSIONS_FILE"
  exit 1
fi

SERVICE_ID="$(jq -r '.service.id' "$PERMISSIONS_FILE")"
SERVICE_NAME="$(jq -r '.service.name' "$PERMISSIONS_FILE")"
SERVICE_DESC="$(jq -r '.service.description' "$PERMISSIONS_FILE")"
SERVICE_AUDIENCE="$(jq -r '.service.audience' "$PERMISSIONS_FILE")"
REG_SERVICE="$(jq -r '.registration.service // .service.id' "$PERMISSIONS_FILE")"
REG_ACTIONS="$(jq -c '.registration.actions // []' "$PERMISSIONS_FILE")"
REG_RESOURCES="$(jq -c '.registration.resources // []' "$PERMISSIONS_FILE")"

if [ -z "$SERVICE_ID" ] || [ "$SERVICE_ID" = "null" ]; then
  echo "ERROR: service.id missing in $PERMISSIONS_FILE"
  exit 1
fi

if [ -z "$REG_SERVICE" ] || [ "$REG_SERVICE" = "null" ]; then
  echo "ERROR: registration.service missing in $PERMISSIONS_FILE"
  exit 1
fi

if [ "$DRY_RUN" = "1" ]; then
  echo "=== DRY RUN: Registration payload preview ==="
  echo "Service ID: $SERVICE_ID"
  echo "Service Name: $SERVICE_NAME"
  echo "Service Audience: $SERVICE_AUDIENCE"
  echo "Permissions file: $PERMISSIONS_FILE"
  echo "Auth Service URL: $AUTH_SERVICE_URL"
  jq -n \
    --arg service "$REG_SERVICE" \
    --arg description "$SERVICE_NAME" \
    --argjson actions "$REG_ACTIONS" \
    --argjson resources "$REG_RESOURCES" \
    '{service: $service, description: $description, actions: $actions, resources: $resources}'
  echo "=== DRY RUN COMPLETE ==="
  exit 0
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# Determine environment suffix from auth service URL
if echo "$AUTH_SERVICE_URL" | grep -qE "localhost|dev\.ab0t\.com"; then
  ENV_SUFFIX="-dev"
else
  ENV_SUFFIX=""
fi

echo -e "${MAGENTA}=== $SERVICE_NAME Registration ===${NC}"
echo "Service ID: $SERVICE_ID"
echo "Environment: ${ENV_SUFFIX:-production}"
echo "Permissions source: $PERMISSIONS_FILE"

mkdir -p "$SETUP_DIR/credentials"

CREDS_FILE="$SETUP_DIR/credentials/${SERVICE_ID}${ENV_SUFFIX}.json"
SOURCE_CREDS_FILE="$CREDS_FILE"

# Fallback: try without suffix if env-specific file doesn't exist
if [ ! -f "$SOURCE_CREDS_FILE" ] && [ -n "$ENV_SUFFIX" ]; then
  FALLBACK="$SETUP_DIR/credentials/${SERVICE_ID}.json"
  if [ -f "$FALLBACK" ]; then
    echo -e "${YELLOW}No ${SERVICE_ID}${ENV_SUFFIX}.json found, using ${SERVICE_ID}.json as seed${NC}"
    SOURCE_CREDS_FILE="$FALLBACK"
  fi
fi

ADMIN_EMAIL=""
ADMIN_PASSWORD=""
EXISTING_ORG_ID=""
EXISTING_API_KEY=""
EXISTING_USER_ID=""

if [ -f "$SOURCE_CREDS_FILE" ]; then
  echo -e "${CYAN}Found existing credentials at $SOURCE_CREDS_FILE${NC}"
  ADMIN_EMAIL="$(jq -r '.admin.email // empty' "$SOURCE_CREDS_FILE")"
  ADMIN_PASSWORD="$(jq -r '.admin.password // empty' "$SOURCE_CREDS_FILE")"
  EXISTING_ORG_ID="$(jq -r '.organization.id // empty' "$SOURCE_CREDS_FILE")"
  EXISTING_API_KEY="$(jq -r '.api_key.key // empty' "$SOURCE_CREDS_FILE")"
  EXISTING_USER_ID="$(jq -r '.admin.user_id // empty' "$SOURCE_CREDS_FILE")"
fi

# INTENT: Admin email can be set via ADMIN_EMAIL env var, or from an existing
# credentials file, or auto-generated from the service ID. The auto-generated
# format uses the ADMIN_EMAIL_DOMAIN env var (default: ab0t.com) so clients
# can use their own domain without editing the script.
if [ -z "$ADMIN_EMAIL" ]; then
  ADMIN_EMAIL_DOMAIN="${ADMIN_EMAIL_DOMAIN:-ab0t.com}"
  ADMIN_EMAIL="${SERVICE_ID}-admin@${ADMIN_EMAIL_DOMAIN}"
fi
if [ -z "$ADMIN_PASSWORD" ]; then
  SERVICE_NAME_NO_SPACES="$(echo "$SERVICE_NAME" | tr -d ' ')"
  ADMIN_PASSWORD="${SERVICE_NAME_NO_SPACES}Admin2024!Secure"
fi

echo -e "${BLUE}Step 1: Setting up admin account${NC}"
REGISTER_PAYLOAD="$(jq -n --arg e "$ADMIN_EMAIL" --arg p "$ADMIN_PASSWORD" --arg n "$SERVICE_NAME Admin" '{email:$e, password:$p, name:$n}')"
REGISTER_RESPONSE="$(curl -s -X POST "$AUTH_SERVICE_URL/auth/register" \
  -H "Content-Type: application/json" \
  -d "$REGISTER_PAYLOAD" 2>&1)"

if echo "$REGISTER_RESPONSE" | grep -q "access_token"; then
  ACCESS_TOKEN="$(echo "$REGISTER_RESPONSE" | jq -r '.access_token')"
  REFRESH_TOKEN="$(echo "$REGISTER_RESPONSE" | jq -r '.refresh_token')"
  USER_ID="$(echo "$REGISTER_RESPONSE" | jq -r '.user.id // .user_info.id // .user_id // empty')"
  echo -e "${GREEN}✓ Admin account created${NC}"
else
  echo -e "${YELLOW}⚠ Admin exists or registration failed, attempting login...${NC}"
  LOGIN_PAYLOAD="$(jq -n --arg e "$ADMIN_EMAIL" --arg p "$ADMIN_PASSWORD" '{email:$e, password:$p}')"
  LOGIN_RESPONSE="$(curl -s -X POST "$AUTH_SERVICE_URL/auth/login" \
    -H "Content-Type: application/json" \
    -d "$LOGIN_PAYLOAD" 2>&1)"

  if ! echo "$LOGIN_RESPONSE" | grep -q "access_token"; then
    echo -e "${RED}✗ Admin login failed${NC}"
    echo "Register response: $REGISTER_RESPONSE"
    echo "Login response: $LOGIN_RESPONSE"
    exit 1
  fi

  ACCESS_TOKEN="$(echo "$LOGIN_RESPONSE" | jq -r '.access_token')"
  REFRESH_TOKEN="$(echo "$LOGIN_RESPONSE" | jq -r '.refresh_token')"
  USER_ID="$(echo "$LOGIN_RESPONSE" | jq -r '.user.id // .user_info.id // .user_id // empty')"
  echo -e "${GREEN}✓ Admin login successful${NC}"
fi

if [ -z "$USER_ID" ] && [ -n "$EXISTING_USER_ID" ]; then
  USER_ID="$EXISTING_USER_ID"
fi

echo -e "${BLUE}Step 2: Finding/creating service organization${NC}"
if [ -n "$EXISTING_ORG_ID" ] && [ "$EXISTING_ORG_ID" != "null" ]; then
  # Verify the cached org still exists on the server
  ORG_CHECK="$(curl -s -o /dev/null -w "%{http_code}" \
    "$AUTH_SERVICE_URL/organizations/$EXISTING_ORG_ID" \
    -H "Authorization: Bearer $ACCESS_TOKEN")"
  if [ "$ORG_CHECK" = "200" ]; then
    ORG_ID="$EXISTING_ORG_ID"
    echo -e "${GREEN}✓ Using existing organization: $ORG_ID${NC}"
  else
    echo -e "${YELLOW}⚠ Cached org $EXISTING_ORG_ID not found (HTTP $ORG_CHECK), creating new one${NC}"
    EXISTING_ORG_ID=""
    EXISTING_API_KEY=""
  fi
fi

if [ -z "${ORG_ID:-}" ]; then
  # Ticket:20260309_service_audience_token_fix Task 6
  # Include service_audience as top-level field (stored on org record for token audience resolution)
  CREATE_ORG_RESPONSE="$(curl -s -X POST "$AUTH_SERVICE_URL/organizations/" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{
      "name": "'"$SERVICE_NAME"'",
      "slug": "'"$SERVICE_ID"'",
      "domain": "'"$SERVICE_ID"'.service.ab0t.com",
      "service_audience": "'"$SERVICE_AUDIENCE"'",
      "billing_type": "enterprise",
      "settings": {
        "type": "platform_service",
        "service": "'"$SERVICE_ID"'",
        "hierarchical": false,
        "internal_service": false
      },
      "metadata": {
        "description": "'"$SERVICE_DESC"'",
        "service_type": "service",
        "data_classification": "sensitive"
      }
    }' 2>&1)"

  if echo "$CREATE_ORG_RESPONSE" | grep -q '"id"'; then
    ORG_ID="$(echo "$CREATE_ORG_RESPONSE" | jq -r '.id')"
    echo -e "${GREEN}✓ Organization created: $ORG_ID${NC}"
  else
    USER_ORGS="$(curl -s -X GET "$AUTH_SERVICE_URL/users/me/organizations" \
      -H "Authorization: Bearer $ACCESS_TOKEN")"
    ORG_ID="$(echo "$USER_ORGS" | jq -r '.[] | select(.slug=="'"$SERVICE_ID"'" or .name=="'"$SERVICE_NAME"'") | .id' | head -n1)"

    if [ -z "$ORG_ID" ] || [ "$ORG_ID" = "null" ]; then
      echo -e "${RED}✗ Could not find existing organization${NC}"
      echo "Create response: $CREATE_ORG_RESPONSE"
      exit 1
    fi
    echo -e "${GREEN}✓ Using existing organization: $ORG_ID${NC}"
  fi
fi

echo -e "${BLUE}Step 3: Logging in with organization context${NC}"
ORG_LOGIN_PAYLOAD="$(jq -n --arg e "$ADMIN_EMAIL" --arg p "$ADMIN_PASSWORD" --arg o "$ORG_ID" '{email:$e, password:$p, org_id:$o}')"
ORG_LOGIN="$(curl -s -X POST "$AUTH_SERVICE_URL/auth/login" \
  -H "Content-Type: application/json" \
  -d "$ORG_LOGIN_PAYLOAD")"
ORG_TOKEN="$(echo "$ORG_LOGIN" | jq -r '.access_token // empty')"

if [ -z "$ORG_TOKEN" ]; then
  echo -e "${YELLOW}⚠ Org login failed, attempting org-scoped register to join org...${NC}"
  # Resolve org slug for org-scoped register
  ORG_SLUG="$(curl -s -X GET "$AUTH_SERVICE_URL/organizations/$ORG_ID" \
    -H "Authorization: Bearer $ACCESS_TOKEN" | jq -r '.slug // empty')"
  if [ -n "$ORG_SLUG" ]; then
    JOIN_PAYLOAD="$(jq -n --arg e "$ADMIN_EMAIL" --arg p "$ADMIN_PASSWORD" --arg n "$SERVICE_NAME Admin" '{email:$e, password:$p, name:$n}')"
    JOIN_RESP="$(curl -s -X POST "$AUTH_SERVICE_URL/organizations/$ORG_SLUG/auth/register" \
      -H "Content-Type: application/json" \
      -d "$JOIN_PAYLOAD")"
    ORG_TOKEN="$(echo "$JOIN_RESP" | jq -r '.access_token // empty')"
  fi

  if [ -z "$ORG_TOKEN" ]; then
    echo -e "${RED}✗ Failed org-context login and join${NC}"
    echo "Response: $ORG_LOGIN"
    exit 1
  fi
  echo -e "${GREEN}✓ Joined organization and got token${NC}"
fi

echo -e "${GREEN}✓ Logged in with organization context${NC}"

echo -e "${BLUE}Step 4: Registering permissions from .permissions.json${NC}"
PERM_RESPONSE="$(curl -s -w "\nHTTP_CODE:%{http_code}" -X POST "$AUTH_SERVICE_URL/permissions/registry/register" \
  -H "Authorization: Bearer $ORG_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "service": "'"$REG_SERVICE"'",
    "description": "'"$SERVICE_NAME"'",
    "actions": '"$REG_ACTIONS"',
    "resources": '"$REG_RESOURCES"'
  }')"

HTTP_CODE="$(echo "$PERM_RESPONSE" | grep "HTTP_CODE" | cut -d: -f2)"
RESPONSE_BODY="$(echo "$PERM_RESPONSE" | grep -v "HTTP_CODE")"

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
  echo -e "${GREEN}✓ Permissions registry updated${NC}"
else
  echo -e "${YELLOW}⚠ Permissions registry response HTTP $HTTP_CODE${NC}"
  echo "$RESPONSE_BODY"
fi

echo -e "${BLUE}Step 4b: Granting implied admin permissions to service admin${NC}"
if [ -n "$USER_ID" ]; then
  ADMIN_PERMS="$(jq -r '.permissions[] | select(.implies != null) | .id' "$PERMISSIONS_FILE")"
  for ADMIN_PERM in $ADMIN_PERMS; do
    curl -s -X POST "$AUTH_SERVICE_URL/permissions/grant?user_id=$USER_ID&org_id=$ORG_ID&permission=$ADMIN_PERM" \
      -H "Authorization: Bearer $ORG_TOKEN" >/dev/null 2>&1 || true

    IMPLIED_PERMS="$(jq -r --arg perm "$ADMIN_PERM" '.permissions[] | select(.id == $perm) | .implies[]?' "$PERMISSIONS_FILE")"
    for IMPLIED in $IMPLIED_PERMS; do
      curl -s -X POST "$AUTH_SERVICE_URL/permissions/grant?user_id=$USER_ID&org_id=$ORG_ID&permission=$IMPLIED" \
        -H "Authorization: Bearer $ORG_TOKEN" >/dev/null 2>&1 || true
    done
  done
  echo -e "${GREEN}✓ Implied admin permissions processed${NC}"
else
  echo -e "${YELLOW}⚠ user_id unavailable; skipped implied grants${NC}"
fi

echo -e "${BLUE}Step 5: Service API key${NC}"
if [ -n "$EXISTING_API_KEY" ] && [ "$EXISTING_API_KEY" != "null" ]; then
  API_KEY="$EXISTING_API_KEY"
  API_KEY_ID="$(jq -r '.api_key.id // empty' "$SOURCE_CREDS_FILE")"
  echo -e "${GREEN}✓ Reusing existing API key${NC}"
else
  ALL_PERMISSIONS="$(jq -r '[.permissions[].id] | map(gsub(":"; ".")) | .[]' "$PERMISSIONS_FILE" | jq -R . | jq -s .)"

  API_KEY_RESPONSE="$(curl -s -X POST "$AUTH_SERVICE_URL/api-keys/" \
    -H "Authorization: Bearer $ORG_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{
      "name": "'"$SERVICE_ID"'-internal",
      "permissions": '"$ALL_PERMISSIONS"',
      "rate_limit": 100000,
      "metadata": {
        "purpose": "Internal '"$SERVICE_NAME"' operations",
        "service_type": "'"$SERVICE_ID"'"
      }
    }' 2>&1)"

  if echo "$API_KEY_RESPONSE" | grep -q '"key"'; then
    API_KEY="$(echo "$API_KEY_RESPONSE" | jq -r '.key')"
    API_KEY_ID="$(echo "$API_KEY_RESPONSE" | jq -r '.id')"
    echo -e "${GREEN}✓ API key created${NC}"
  else
    echo -e "${YELLOW}⚠ Could not create API key${NC}"
    echo "$API_KEY_RESPONSE"
    API_KEY=""
    API_KEY_ID=""
  fi
fi

if [ -f "$CREDS_FILE" ]; then
  BACKUP_FILE="$CREDS_FILE.bak.$(date +%Y%m%d_%H%M%S)"
  cp "$CREDS_FILE" "$BACKUP_FILE"
  echo -e "${CYAN}Backed up existing credentials: $BACKUP_FILE${NC}"
fi

# Ticket:20260309_service_audience_token_fix Task 6
# Use service-name audience (RFC 9068 §3) instead of LOCAL:{org_id}
AUTH_AUDIENCE="${SERVICE_AUDIENCE}"

# ── Persist credentials + raw server responses ───────────────────────────
# Top-level fields preserve the historical shape (back-compat for downstream
# scripts). _raw.* preserves every JSON response we received during this run
# so future operations don't have to re-derive expiry, scopes, normalized
# slugs, server-side defaults, etc. See SUGGESTIONS.md for rationale.
_safe_json() {
  printf '%s' "${1:-}" | jq -e . >/dev/null 2>&1 && printf '%s' "$1" || printf '{}'
}

RAW_REGISTER="$(_safe_json "${REGISTER_RESPONSE:-}")"
RAW_LOGIN="$(_safe_json "${LOGIN_RESPONSE:-}")"
RAW_CREATE_ORG="$(_safe_json "${CREATE_ORG_RESPONSE:-}")"
RAW_ORG_LOGIN="$(_safe_json "${ORG_LOGIN:-}")"
RAW_JOIN="$(_safe_json "${JOIN_RESP:-}")"
RAW_PERM_REGISTRY="$(_safe_json "${RESPONSE_BODY:-}")"
RAW_API_KEY="$(_safe_json "${API_KEY_RESPONSE:-}")"

jq -n \
  --arg service "$SERVICE_ID" \
  --arg service_audience "$SERVICE_AUDIENCE" \
  --arg audience "$AUTH_AUDIENCE" \
  --arg org_id "$ORG_ID" \
  --arg org_name "$SERVICE_NAME" \
  --arg org_slug "$SERVICE_ID" \
  --arg admin_email "$ADMIN_EMAIL" \
  --arg admin_password "$ADMIN_PASSWORD" \
  --arg user_id "${USER_ID:-}" \
  --arg access_token "$ORG_TOKEN" \
  --arg refresh_token "${REFRESH_TOKEN:-}" \
  --arg api_key_id "${API_KEY_ID:-}" \
  --arg api_key "${API_KEY:-}" \
  --arg created_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  --argjson raw_register "$RAW_REGISTER" \
  --argjson raw_login "$RAW_LOGIN" \
  --argjson raw_create_org "$RAW_CREATE_ORG" \
  --argjson raw_org_login "$RAW_ORG_LOGIN" \
  --argjson raw_join "$RAW_JOIN" \
  --argjson raw_perm_registry "$RAW_PERM_REGISTRY" \
  --argjson raw_api_key "$RAW_API_KEY" \
  '{
    service: $service,
    service_audience: $service_audience,
    auth: {audience: $audience},
    organization: {id: $org_id, name: $org_name, slug: $org_slug},
    admin: {
      email: $admin_email,
      password: $admin_password,
      user_id: $user_id,
      access_token: $access_token,
      refresh_token: $refresh_token
    },
    api_key: {id: $api_key_id, key: $api_key},
    permissions_source: ".permissions.json",
    created_at: $created_at,
    _raw: {
      register: $raw_register,
      login: $raw_login,
      create_org: $raw_create_org,
      org_login: $raw_org_login,
      join: $raw_join,
      permissions_registry_register: $raw_perm_registry,
      api_key_create: $raw_api_key
    }
  }' > "$CREDS_FILE"

chmod 600 "$CREDS_FILE" 2>/dev/null || true

echo -e "${GREEN}✓ Credentials saved: $CREDS_FILE${NC}"

if [ "$REGISTER_PROXY" = "1" ]; then
  echo -e "${BLUE}Step 6: Proxy registration${NC}"
  PUBLIC_IP="$(curl -s http://checkip.amazonaws.com || true)"
  if [ -z "$PUBLIC_IP" ]; then
    PUBLIC_IP="127.0.0.1"
  fi

  PROXY_RESPONSE="$(curl -s -w "\n%{http_code}" -X POST "https://controller.proxy.ab0t.com/v1/service/services" \
    -H "Content-Type: application/json" \
    -d "{
      \"service_id\": \"$SERVICE_ID\",
      \"ip\": \"$PUBLIC_IP\",
      \"port\": $SERVICE_PORT,
      \"ttl_seconds\": 2592000,
      \"description\": \"$SERVICE_DESC\",
      \"weight\": 100,
      \"create_only\": true
    }")"

  PROXY_HTTP="$(echo "$PROXY_RESPONSE" | tail -n1)"
  if [ "$PROXY_HTTP" = "200" ] || [ "$PROXY_HTTP" = "201" ]; then
    echo -e "${GREEN}✓ Proxy registration succeeded${NC}"
  else
    echo -e "${YELLOW}⚠ Proxy registration returned HTTP $PROXY_HTTP${NC}"
  fi
else
  echo -e "${BLUE}Step 6: Proxy registration skipped (REGISTER_PROXY=0)${NC}"
fi

echo -e "${CYAN}=== Registration complete ===${NC}"
echo "Service ID: $SERVICE_ID"
echo "Organization ID: $ORG_ID"
echo "Auth audience: $AUTH_AUDIENCE"
echo "Service audience: $SERVICE_AUDIENCE"
echo "Credentials: $CREDS_FILE"
