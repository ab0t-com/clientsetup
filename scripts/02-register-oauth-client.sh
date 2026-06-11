#!/bin/bash
# Register an OAuth client for a frontend application.
#
# This script:
#   1. Reads client config from config/oauth-client.json (what to register)
#   2. Reads service credentials (who to auth as)
#   3. Registers a public OAuth client (authorization_code + PKCE)
#   4. Saves the result to credentials/oauth-client.json (or oauth-client-dev.json)
#
# Environment-aware: when AUTH_SERVICE_URL points to localhost or *.dev.ab0t.com,
# reads from {service}-dev.json and writes to oauth-client-dev.json.
# Production (auth.service.ab0t.com) uses the unsuffixed filenames.
#
# Prerequisites:
#   - config/oauth-client.json must exist
#   - credentials/{service}.json must exist (from 01-register-service-permissions.sh)
#   - jq and python3 must be available
#
# Usage:
#   ./scripts/02-register-oauth-client.sh
#   AUTH_SERVICE_URL=https://auth.dev.ab0t.com ./scripts/02-register-oauth-client.sh
#   DRY_RUN=1 ./scripts/02-register-oauth-client.sh

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

# Load client config
CLIENT_CONFIG="${CLIENT_CONFIG:-$SETUP_DIR/config/oauth-client.json}"
if [ ! -f "$CLIENT_CONFIG" ]; then
  echo -e "${RED}ERROR: $CLIENT_CONFIG not found.${NC}"
  echo "Create .oauth-client.json with: client_name, redirect_uris, grant_types, response_types, scope"
  exit 1
fi

# Validate client config has required fields
for field in client_name redirect_uris; do
  val="$(jq -r ".$field // empty" "$CLIENT_CONFIG")"
  if [ -z "$val" ]; then
    echo -e "${RED}ERROR: '$field' missing in $CLIENT_CONFIG${NC}"
    exit 1
  fi
done

CLIENT_NAME="$(jq -r '.client_name' "$CLIENT_CONFIG")"
REDIRECT_URIS="$(jq -c '.redirect_uris' "$CLIENT_CONFIG")"

# Determine environment suffix from auth service URL
# localhost or *.dev.ab0t.com -> "-dev" suffix
if echo "$AUTH_SERVICE_URL" | grep -qE "localhost|dev\.ab0t\.com"; then
  ENV_SUFFIX="-dev"
else
  ENV_SUFFIX=""
fi

# Load service credentials (match the environment)
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

OUTPUT_FILE="$SETUP_DIR/credentials/oauth-client${ENV_SUFFIX}.json"

# Check if already registered — support update mode
UPDATE_MODE=false
EXISTING_ID=""
EXISTING_REG_TOKEN=""
EXISTING_REG_URI=""

if [ -f "$OUTPUT_FILE" ]; then
  EXISTING_ID="$(jq -r '.client_id // empty' "$OUTPUT_FILE")"
  EXISTING_REG_TOKEN="$(jq -r '.registration_access_token // empty' "$OUTPUT_FILE")"
  EXISTING_REG_URI="$(jq -r '.registration_client_uri // empty' "$OUTPUT_FILE")"

  if [ -n "$EXISTING_ID" ]; then
    echo -e "${YELLOW}OAuth client already registered: $EXISTING_ID${NC}"
    echo -e "${YELLOW}Saved at: $OUTPUT_FILE${NC}"
    echo ""
    if [ -n "$EXISTING_REG_TOKEN" ] && [ -n "$EXISTING_REG_URI" ]; then
      if [ -t 0 ]; then
        echo "  [U] Update existing client (recommended)"
        echo "  [N] Register a NEW client (old one stays valid)"
        echo "  [Q] Quit"
        read -p "Choice [U/n/q]: " -r
        case "$REPLY" in
          [Nn]) UPDATE_MODE=false ;;
          [Qq]) echo "Keeping existing client."; exit 0 ;;
          *)    UPDATE_MODE=true ;;
        esac
      else
        echo -e "${GREEN}Auto-updating existing client (non-interactive)${NC}"
        UPDATE_MODE=true
      fi
    else
      if [ -t 0 ]; then
        read -p "Re-register? This will create a NEW client (old one stays valid). [y/N] " -r
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
          echo "Keeping existing client."
          exit 0
        fi
      else
        echo -e "${GREEN}Auto-registering new client (non-interactive)${NC}"
      fi
    fi
    echo ""
  fi
fi

echo -e "${CYAN}=== OAuth Client $([ "$UPDATE_MODE" = true ] && echo "Update" || echo "Registration") ===${NC}"
echo ""
echo "Config:         $CLIENT_CONFIG"
echo "Credentials:    $CREDS_FILE"
echo "Auth Service:   $AUTH_SERVICE_URL"
echo "Org:            $ORG_SLUG ($ORG_ID)"
echo "Client Name:    $CLIENT_NAME"
echo "Redirect URIs:"
echo "$REDIRECT_URIS" | jq -r '.[]' | sed 's/^/  - /'
echo "Output:         $OUTPUT_FILE"
if [ "$UPDATE_MODE" = true ]; then
  echo "Mode:           UPDATE (client $EXISTING_ID)"
fi
echo ""

# Build registration payload: merge client config + org_id
PAYLOAD="$(jq --arg org_id "$ORG_ID" '. + {org_id: $org_id}' "$CLIENT_CONFIG")"

if [ "$DRY_RUN" = "1" ]; then
  echo -e "${YELLOW}=== DRY RUN ===${NC}"
  if [ "$UPDATE_MODE" = true ]; then
    echo "Would PUT to: $EXISTING_REG_URI"
  else
    echo "Would POST to: $AUTH_SERVICE_URL/auth/oauth/register"
  fi
  echo "$PAYLOAD" | jq .
  echo -e "${YELLOW}=== DRY RUN COMPLETE ===${NC}"
  exit 0
fi

if [ "$UPDATE_MODE" = true ]; then
  # ── Update existing client via RFC 7592 management endpoint ──

  echo -e "${BLUE}Step 1: Updating existing client via management endpoint${NC}"

  RESPONSE="$(curl -s -w "\nHTTP_CODE:%{http_code}" \
    -X PUT "$EXISTING_REG_URI" \
    -H "Authorization: Bearer $EXISTING_REG_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD")"

  HTTP_CODE="$(echo "$RESPONSE" | grep "HTTP_CODE" | cut -d: -f2)"
  RESPONSE_BODY="$(echo "$RESPONSE" | grep -v "HTTP_CODE")"

  if [ "$HTTP_CODE" = "200" ]; then
    CLIENT_ID="$EXISTING_ID"
    echo -e "${GREEN}Client updated: $CLIENT_ID${NC}"
  else
    echo -e "${RED}Update failed (HTTP $HTTP_CODE)${NC}"
    echo "$RESPONSE_BODY" | jq . 2>/dev/null || echo "$RESPONSE_BODY"
    echo ""
    echo -e "${YELLOW}Falling back to login + re-register...${NC}"
    UPDATE_MODE=false
  fi
fi

if [ "$UPDATE_MODE" = false ]; then
  # ── Register new client (original flow) ──

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

  # Step 2: Register OAuth client
  echo -e "${BLUE}Step 2: Registering OAuth client${NC}"

  RESPONSE="$(curl -s -w "\nHTTP_CODE:%{http_code}" \
    -X POST "$AUTH_SERVICE_URL/auth/oauth/register" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD")"

  HTTP_CODE="$(echo "$RESPONSE" | grep "HTTP_CODE" | cut -d: -f2)"
  RESPONSE_BODY="$(echo "$RESPONSE" | grep -v "HTTP_CODE")"

  if [ "$HTTP_CODE" != "200" ] && [ "$HTTP_CODE" != "201" ]; then
    echo -e "${RED}Registration failed (HTTP $HTTP_CODE)${NC}"
    echo "$RESPONSE_BODY" | jq . 2>/dev/null || echo "$RESPONSE_BODY"
    exit 1
  fi

  CLIENT_ID="$(echo "$RESPONSE_BODY" | jq -r '.client_id')"
  echo -e "${GREEN}Client registered: $CLIENT_ID${NC}"
fi

# Step 3: Save result
echo -e "${BLUE}Step 3: Saving credentials${NC}"

META_ACTION="$([ "$UPDATE_MODE" = true ] && echo "updated_at" || echo "registered_at")"
OUTPUT="$(echo "$RESPONSE_BODY" | jq \
  --arg slug "$ORG_SLUG" \
  --arg org_id "$ORG_ID" \
  --arg url "$AUTH_SERVICE_URL" \
  --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg config "$CLIENT_CONFIG" \
  --arg action "$META_ACTION" \
  '. + {
    _meta: {
      org_slug: $slug,
      org_id: $org_id,
      auth_service_url: $url,
      source_config: $config,
      ($action): $date
    }
  }')"

mkdir -p "$SETUP_DIR/credentials"
echo "$OUTPUT" | jq . > "$OUTPUT_FILE"
echo -e "${GREEN}Saved to: $OUTPUT_FILE${NC}"

# Step 4: Verify
echo -e "${BLUE}Step 4: Verifying client works${NC}"

if [ "$UPDATE_MODE" = true ]; then
  # In update mode, verify via the management endpoint using the reg token
  VERIFY_CODE="$(curl -s -o /dev/null -w "%{http_code}" \
    "$EXISTING_REG_URI" \
    -H "Authorization: Bearer $EXISTING_REG_TOKEN")"

  if [ "$VERIFY_CODE" = "200" ]; then
    VERIFY_METHOD="$(curl -s "$EXISTING_REG_URI" \
      -H "Authorization: Bearer $EXISTING_REG_TOKEN" | jq -r '.token_endpoint_auth_method // empty')"
    echo -e "${GREEN}Verified: token_endpoint_auth_method = $VERIFY_METHOD${NC}"
  else
    echo -e "${YELLOW}Could not verify client (HTTP $VERIFY_CODE) — update may still have worked${NC}"
  fi
else
  VERIFY_CODE="$(curl -s -o /dev/null -w "%{http_code}" \
    "$AUTH_SERVICE_URL/organizations/$ORG_ID/clients" \
    -H "Authorization: Bearer $ACCESS_TOKEN")"

  if [ "$VERIFY_CODE" = "200" ]; then
    CLIENT_COUNT="$(curl -s "$AUTH_SERVICE_URL/organizations/$ORG_ID/clients" \
      -H "Authorization: Bearer $ACCESS_TOKEN" | jq 'length')"
    echo -e "${GREEN}Org has $CLIENT_COUNT registered client(s)${NC}"
  else
    echo -e "${YELLOW}Could not verify client list (HTTP $VERIFY_CODE) — client may still work${NC}"
  fi
fi

echo ""
echo -e "${CYAN}=== Registration Complete ===${NC}"
echo ""
echo "Client ID:    $CLIENT_ID"
echo "Saved to:     $OUTPUT_FILE"
echo ""
echo "Use in frontend:"
echo "  var auth = new AuthMesh.AuthMeshClient({"
echo "      domain: '$AUTH_SERVICE_URL',"
echo "      org: '$ORG_SLUG',"
echo "      clientId: '$CLIENT_ID',"
echo "      redirectUri: window.location.origin + '/auth/callback',"
echo "      scope: 'openid profile email',"
echo "  });"
echo ""

# USAGE EXAMPLES:
# cd /home/ubuntu/infra/infra/code/intergration/output && echo "U" | AUTH_SERVICE_URL=https://auth.service.ab0t.com ./register-oauth-client.sh
