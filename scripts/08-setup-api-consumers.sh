#!/bin/bash
# ==============================================================================
# 08-setup-api-consumers.sh — Open YOUR service as a PROVIDER for other mesh services
#
# INTENT:
#   YOU WANT OTHER SERVICES TO CALL YOUR APIs.
#
#   This is the PROVIDER side of the mesh. Run this when you want other
#   services to be able to self-register as consumers of YOUR service.
#   It creates a consumer registration org where other services sign up,
#   auto-join a permissions team, and get scoped API keys — without any
#   manual approval from you after initial setup.
#
#   This is the opposite of step 07. Step 07 registers you as a consumer
#   of OTHER services. Step 08 opens YOUR service so others can consume it.
#
#   Direction: OTHER SERVICES → call → YOUR SERVICE
#
# WHO RUNS THIS:
#   Any service that wants to be consumed by other mesh services.
#   Run after step 01 (your service must be registered first).
#
# ANALOGY:
#   This is the service-account equivalent of step 04 (setup-default-team.sh).
#   Step 04 creates an end-users org where HUMANS self-register.
#   This script creates a consumers org where SERVICES self-register.
#   Same Zanzibar pattern: org → team → permissions → auto-join.
#
# Architecture:
#   Service Org (billing)
#     └── {service}-api-consumers (child org, parent_id = service org)
#           ├── "Read-Only Consumers" team (default auto-join)
#           │     └── [service.read.*, service.cross_tenant]
#           ├── "Standard Consumers" team (upgrade tier)
#           │     └── [read + safe writes + cross_tenant]
#           └── login config:
#                 default_role = service_account
#                 default_team = read-only-team-id
#                 signup_enabled = true
#
#   When a service registers:
#     1. POST /organizations/{slug}/auth/register
#     2. Auth reads login config → default_team
#     3. Service account auto-joins "Read-Only Consumers" team
#     4. Inherits read permissions via Zanzibar
#     5. Creates API key with those permissions
#
# After this script runs, consumers self-register with TWO API calls.
# No provider involvement needed.
#
# IDEMPOTENT: Detects existing org and teams, skips creation.
#
# Prerequisites:
#   - credentials/{service}.json must exist (from 01-register-service-permissions.sh)
#   - config/permissions.json must exist
#   - config/api-consumers.json must exist (or will be auto-generated)
#   - jq, curl must be available
#
# Usage:
#   ./scripts/08-setup-api-consumers.sh
#   AUTH_SERVICE_URL=https://auth.service.ab0t.com ./scripts/08-setup-api-consumers.sh
#   DRY_RUN=1 ./scripts/08-setup-api-consumers.sh
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_DIR="${SETUP_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
AUTH_SERVICE_URL="${AUTH_SERVICE_URL:-https://auth.service.ab0t.com}"
DRY_RUN="${DRY_RUN:-0}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

for cmd in jq curl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo -e "${RED}ERROR: $cmd is required${NC}"; exit 1
  fi
done

# ── Load configs ──────────────────────────────────────────────────────

PERMISSIONS_FILE="${PERMISSIONS_FILE:-$SETUP_DIR/config/permissions.json}"
CONSUMERS_FILE="${CONSUMERS_FILE:-$SETUP_DIR/config/api-consumers.json}"

if [ ! -f "$PERMISSIONS_FILE" ]; then
  echo -e "${RED}ERROR: $PERMISSIONS_FILE not found${NC}"; exit 1
fi

# Auto-generate api-consumers.json if it doesn't exist
if [ ! -f "$CONSUMERS_FILE" ]; then
  echo -e "${YELLOW}No api-consumers.json found — auto-generating from permissions.json${NC}"

  SERVICE_PREFIX="$(jq -r '.registration.service // .service.id' "$PERMISSIONS_FILE")"

  # Read-Only: all read permissions + cross_tenant/cross_org
  READ_PERMS=$(jq -c "[.permissions[] | select(.id | test(\"\\\\.(read|cross)\")) | .id]" "$PERMISSIONS_FILE")

  # Standard: all default_grant + cross_tenant/cross_org
  STD_PERMS=$(jq -c "([.permissions[] | select(.default_grant == true) | .id] + [.permissions[] | select(.id | test(\"cross\")) | .id]) | unique" "$PERMISSIONS_FILE")

  cat > "$CONSUMERS_FILE" <<GENEOF
{
    "consumer_org": {
        "name_suffix": "API Consumers",
        "slug_suffix": "api-consumers",
        "description": "Self-service consumer registration"
    },
    "tiers": [
        {
            "name": "Read-Only Consumers",
            "description": "Read-only access — dashboards, analytics, monitoring",
            "default": true,
            "permissions": $READ_PERMS
        },
        {
            "name": "Standard Consumers",
            "description": "Read + write access — active integrations",
            "default": false,
            "permissions": $STD_PERMS
        }
    ],
    "registration": {
        "signup_enabled": true,
        "require_email_verification": false,
        "default_role": "service_account"
    }
}
GENEOF

  echo -e "${GREEN}Generated: $CONSUMERS_FILE${NC}"
fi

# ── Determine environment and load service credentials ────────────────

if echo "$AUTH_SERVICE_URL" | grep -qE "localhost|dev\.ab0t\.com"; then
  ENV_SUFFIX="-dev"
else
  ENV_SUFFIX=""
fi

SERVICE_ID="$(jq -r '.service.id' "$PERMISSIONS_FILE")"
SERVICE_NAME="$(jq -r '.service.name // .service.id' "$PERMISSIONS_FILE")"
CREDS_FILE="$SETUP_DIR/credentials/${SERVICE_ID}${ENV_SUFFIX}.json"

if [ ! -f "$CREDS_FILE" ] && [ -n "$ENV_SUFFIX" ]; then
  FALLBACK="$SETUP_DIR/credentials/${SERVICE_ID}.json"
  [ -f "$FALLBACK" ] && CREDS_FILE="$FALLBACK"
fi

if [ ! -f "$CREDS_FILE" ]; then
  echo -e "${RED}ERROR: No credentials found. Run 01-register-service-permissions.sh first.${NC}"
  exit 1
fi

SERVICE_ORG_ID="$(jq -r '.organization.id' "$CREDS_FILE")"
SERVICE_ORG_SLUG="$(jq -r '.organization.slug // .service' "$CREDS_FILE")"

# ── Load consumer config ─────────────────────────────────────────────

ORG_NAME_SUFFIX="$(jq -r '.consumer_org.name_suffix // "API Consumers"' "$CONSUMERS_FILE")"
ORG_SLUG_SUFFIX="$(jq -r '.consumer_org.slug_suffix // "api-consumers"' "$CONSUMERS_FILE")"
CONSUMER_ORG_NAME="${SERVICE_NAME} ${ORG_NAME_SUFFIX}"
CONSUMER_ORG_SLUG="${SERVICE_ID}-${ORG_SLUG_SUFFIX}"
DEFAULT_ROLE="$(jq -r '.registration.default_role // "service_account"' "$CONSUMERS_FILE")"
TIER_COUNT="$(jq '.tiers | length' "$CONSUMERS_FILE")"
OUTPUT_FILE="$SETUP_DIR/credentials/api-consumers${ENV_SUFFIX}.json"

REG_SERVICE="$(jq -r '.registration.service // .service.id' "$PERMISSIONS_FILE")"
REG_ACTIONS="$(jq -c '.registration.actions // []' "$PERMISSIONS_FILE")"
REG_RESOURCES="$(jq -c '.registration.resources // []' "$PERMISSIONS_FILE")"
SERVICE_DESC="$(jq -r '.service.description // .service.name' "$PERMISSIONS_FILE")"

echo -e "${CYAN}=== API Consumer Org Setup ===${NC}"
echo ""
echo "  Service:         $SERVICE_NAME ($SERVICE_ID)"
echo "  Service Org:     $SERVICE_ORG_SLUG ($SERVICE_ORG_ID)"
echo "  Consumer Org:    $CONSUMER_ORG_SLUG"
echo "  Default Role:    $DEFAULT_ROLE"
echo "  Tiers:           $TIER_COUNT"
echo "  Auth Service:    $AUTH_SERVICE_URL"
echo "  Output:          $OUTPUT_FILE"
echo ""

if [ "$DRY_RUN" = "1" ]; then
  echo -e "${YELLOW}=== DRY RUN ===${NC}"
  echo "Would create: $CONSUMER_ORG_SLUG (parent: $SERVICE_ORG_ID)"
  for i in $(seq 0 $((TIER_COUNT - 1))); do
    T_NAME=$(jq -r ".tiers[$i].name" "$CONSUMERS_FILE")
    T_DEFAULT=$(jq -r ".tiers[$i].default" "$CONSUMERS_FILE")
    T_PERM_COUNT=$(jq ".tiers[$i].permissions | length" "$CONSUMERS_FILE")
    echo "Would create team: $T_NAME ($T_PERM_COUNT perms, default=$T_DEFAULT)"
  done
  echo "Would configure login: default_role=$DEFAULT_ROLE, signup_enabled=true"
  echo -e "${YELLOW}=== DRY RUN COMPLETE ===${NC}"
  exit 0
fi

# ── Step 1: Login as service admin ────────────────────────────────────

echo -e "${BLUE}Step 1: Logging in as service admin${NC}"

LOGIN_RESP="$(curl -s -w "\nHTTP_CODE:%{http_code}" \
  -X POST "$AUTH_SERVICE_URL/auth/login" \
  -H "Content-Type: application/json" \
  -d "$(jq -n \
    --arg email "$(jq -r '.admin.email' "$CREDS_FILE")" \
    --arg password "$(jq -r '.admin.password' "$CREDS_FILE")" \
    --arg org_id "$(jq -r '.organization.id' "$CREDS_FILE")" \
    '{email: $email, password: $password, org_id: $org_id}')")"

HTTP_CODE="$(echo "$LOGIN_RESP" | grep "HTTP_CODE" | cut -d: -f2)"
RESP_BODY="$(echo "$LOGIN_RESP" | grep -v "HTTP_CODE")"
ACCESS_TOKEN="$(echo "$RESP_BODY" | jq -r '.access_token // empty')"

if [ -z "$ACCESS_TOKEN" ]; then
  echo -e "${RED}Login failed (HTTP $HTTP_CODE)${NC}"
  echo "$RESP_BODY" | jq . 2>/dev/null || echo "$RESP_BODY"
  exit 1
fi
echo -e "${GREEN}  Logged in${NC}"

# ── Step 2: Find or create consumer org ───────────────────────────────

echo -e "${BLUE}Step 2: Finding/creating consumer org${NC}"

CONSUMER_ORG_ID=""

# Check output file first
if [ -f "$OUTPUT_FILE" ]; then
  EXISTING_ID="$(jq -r '.org_id // empty' "$OUTPUT_FILE")"
  if [ -n "$EXISTING_ID" ]; then
    CHECK_CODE="$(curl -s -o /dev/null -w "%{http_code}" \
      "$AUTH_SERVICE_URL/organizations/$EXISTING_ID" \
      -H "Authorization: Bearer $ACCESS_TOKEN")"
    if [ "$CHECK_CODE" = "200" ]; then
      CONSUMER_ORG_ID="$EXISTING_ID"
      echo -e "${GREEN}  Found existing (from output file): $CONSUMER_ORG_ID${NC}"
    fi
  fi
fi

# Search by slug
if [ -z "$CONSUMER_ORG_ID" ]; then
  USER_ORGS="$(curl -s "$AUTH_SERVICE_URL/users/me/organizations" \
    -H "Authorization: Bearer $ACCESS_TOKEN" 2>/dev/null || echo "[]")"
  FOUND_ID="$(echo "$USER_ORGS" | jq -r '.[] | select(.slug=="'"$CONSUMER_ORG_SLUG"'") | .id' 2>/dev/null | head -n1)"
  if [ -n "$FOUND_ID" ] && [ "$FOUND_ID" != "null" ]; then
    CONSUMER_ORG_ID="$FOUND_ID"
    echo -e "${GREEN}  Found existing (by slug): $CONSUMER_ORG_ID${NC}"
  fi
fi

# Create
if [ -z "$CONSUMER_ORG_ID" ]; then
  CREATE_RESP="$(curl -s -w "\nHTTP_CODE:%{http_code}" \
    -X POST "$AUTH_SERVICE_URL/organizations/" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{
      "name": "'"$CONSUMER_ORG_NAME"'",
      "slug": "'"$CONSUMER_ORG_SLUG"'",
      "parent_id": "'"$SERVICE_ORG_ID"'",
      "billing_type": "enterprise",
      "settings": {
        "type": "api_consumers",
        "service": "'"$SERVICE_ID"'",
        "purpose": "self_service_consumer_registration"
      }
    }')"

  HTTP_CODE="$(echo "$CREATE_RESP" | grep "HTTP_CODE" | cut -d: -f2)"
  RESP_BODY="$(echo "$CREATE_RESP" | grep -v "HTTP_CODE")"

  if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
    CONSUMER_ORG_ID="$(echo "$RESP_BODY" | jq -r '.id')"
    echo -e "${GREEN}  Created: $CONSUMER_ORG_ID (parent: $SERVICE_ORG_ID)${NC}"
  else
    echo -e "${RED}  Failed (HTTP $HTTP_CODE)${NC}"
    echo "$RESP_BODY" | jq . 2>/dev/null || echo "$RESP_BODY"
    exit 1
  fi
fi

# ── Step 3: Switch to consumer org context ────────────────────────────

echo -e "${BLUE}Step 3: Getting consumer org context${NC}"

CON_LOGIN="$(curl -s -X POST "$AUTH_SERVICE_URL/auth/login" \
  -H "Content-Type: application/json" \
  -d "$(jq -n \
    --arg email "$(jq -r '.admin.email' "$CREDS_FILE")" \
    --arg password "$(jq -r '.admin.password' "$CREDS_FILE")" \
    --arg org_id "$CONSUMER_ORG_ID" \
    '{email: $email, password: $password, org_id: $org_id}')")"

CON_TOKEN="$(echo "$CON_LOGIN" | jq -r '.access_token // empty')"
if [ -z "$CON_TOKEN" ]; then
  echo -e "${YELLOW}  Could not login with consumer org context, using admin token${NC}"
  CON_TOKEN="$ACCESS_TOKEN"
fi
echo -e "${GREEN}  Got context token${NC}"

# ── Step 4: Register permission schema on consumer org ────────────────

echo -e "${BLUE}Step 4: Registering permission schema${NC}"

PERM_RESP="$(curl -s -w "\nHTTP_CODE:%{http_code}" \
  -X POST "$AUTH_SERVICE_URL/permissions/registry/register" \
  -H "Authorization: Bearer $CON_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "service": "'"$REG_SERVICE"'",
    "description": "'"$SERVICE_DESC"'",
    "actions": '"$REG_ACTIONS"',
    "resources": '"$REG_RESOURCES"'
  }')"

HTTP_CODE="$(echo "$PERM_RESP" | grep "HTTP_CODE" | cut -d: -f2)"
if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
  echo -e "${GREEN}  Permission schema registered on consumer org${NC}"
else
  echo -e "${YELLOW}  Permission registry returned HTTP $HTTP_CODE (non-fatal)${NC}"
fi

# ── Step 5: Create tier teams ─────────────────────────────────────────

echo -e "${BLUE}Step 5: Creating tier teams${NC}"

DEFAULT_TEAM_ID=""
TIERS_JSON="[]"

for i in $(seq 0 $((TIER_COUNT - 1))); do
  T_NAME=$(jq -r ".tiers[$i].name" "$CONSUMERS_FILE")
  T_DESC=$(jq -r ".tiers[$i].description" "$CONSUMERS_FILE")
  T_DEFAULT=$(jq -r ".tiers[$i].default" "$CONSUMERS_FILE")
  T_PERMS=$(jq -c ".tiers[$i].permissions" "$CONSUMERS_FILE")
  T_PERM_COUNT=$(echo "$T_PERMS" | jq 'length')

  echo -e "  ${CYAN}Tier: $T_NAME ($T_PERM_COUNT perms, default=$T_DEFAULT)${NC}"

  # Check if team exists
  EXISTING_TEAMS="$(curl -s "$AUTH_SERVICE_URL/organizations/$CONSUMER_ORG_ID/teams" \
    -H "Authorization: Bearer $CON_TOKEN" 2>/dev/null || echo "[]")"
  FOUND_TEAM="$(echo "$EXISTING_TEAMS" | jq -r --arg name "$T_NAME" \
    '.[] | select(.name == $name) | .id' 2>/dev/null | head -n1)"

  RAW_TEAM=""
  if [ -n "$FOUND_TEAM" ] && [ "$FOUND_TEAM" != "null" ]; then
    TEAM_ID="$FOUND_TEAM"
    echo -e "  ${GREEN}Exists: $TEAM_ID${NC}"
    # Capture the existing team's full record from the list response
    RAW_TEAM="$(echo "$EXISTING_TEAMS" | jq --arg id "$TEAM_ID" '.[] | select(.id == $id)' 2>/dev/null)"
  else
    TEAM_RESP="$(curl -s -X POST "$AUTH_SERVICE_URL/organizations/$CONSUMER_ORG_ID/teams" \
      -H "Authorization: Bearer $CON_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{
        \"name\": \"$T_NAME\",
        \"description\": \"$T_DESC\",
        \"permissions\": $T_PERMS
      }")"
    TEAM_ID="$(echo "$TEAM_RESP" | jq -r '.id // .team_id // empty')"
    RAW_TEAM="$TEAM_RESP"

    if [ -n "$TEAM_ID" ] && [ "$TEAM_ID" != "null" ]; then
      echo -e "  ${GREEN}Created: $TEAM_ID${NC}"
    else
      echo -e "  ${RED}Failed to create team${NC}"
      echo "  $TEAM_RESP"
      continue
    fi
  fi

  if [ "$T_DEFAULT" = "true" ]; then
    DEFAULT_TEAM_ID="$TEAM_ID"
  fi

  # Validate the raw response is JSON; fall back to {} so jq doesn't choke
  RAW_TEAM_JSON="$(printf '%s' "$RAW_TEAM" | jq -e . >/dev/null 2>&1 && printf '%s' "$RAW_TEAM" || printf '{}')"

  # Accumulate tier info for output. _raw.team holds the server's view of
  # the team (actual permissions granted may differ from $T_PERMS — the
  # server can filter or normalize). See SUGGESTIONS.md for rationale.
  TIERS_JSON=$(echo "$TIERS_JSON" | jq \
    --arg name "$T_NAME" \
    --arg team_id "$TEAM_ID" \
    --argjson default "$T_DEFAULT" \
    --argjson perms "$T_PERMS" \
    --argjson raw_team "$RAW_TEAM_JSON" \
    '. + [{name: $name, team_id: $team_id, default: $default, permissions: $perms, permission_count: ($perms | length), _raw: {team: $raw_team}}]')
done

echo ""

# ── Step 6: Configure login with auto-join ────────────────────────────

echo -e "${BLUE}Step 6: Configuring login (auto-join + service_account role)${NC}"

if [ -z "$DEFAULT_TEAM_ID" ]; then
  echo -e "${RED}  No default tier team found — cannot configure auto-join${NC}"
  exit 1
fi

LOGIN_RESP="$(curl -s -w "\nHTTP_CODE:%{http_code}" \
  -X PUT "$AUTH_SERVICE_URL/organizations/$CONSUMER_ORG_ID/login-config" \
  -H "Authorization: Bearer $CON_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "auth_methods": {
      "email_password": true,
      "signup_enabled": '"$(jq '.registration.signup_enabled // true' "$CONSUMERS_FILE")"',
      "invitation_only": false
    },
    "registration": {
      "default_role": "'"$DEFAULT_ROLE"'",
      "default_team": "'"$DEFAULT_TEAM_ID"'",
      "collect_name": true
    },
    "branding": {
      "page_title": "'"$SERVICE_NAME"' — API Consumer Registration"
    }
  }')"

HTTP_CODE="$(echo "$LOGIN_RESP" | grep "HTTP_CODE" | cut -d: -f2)"
LOGIN_CONFIG_PUT_BODY="$(echo "$LOGIN_RESP" | grep -v "HTTP_CODE")"
if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
  echo -e "${GREEN}  Login config applied${NC}"
  echo "  default_role: $DEFAULT_ROLE"
  echo "  default_team: $DEFAULT_TEAM_ID"
  echo "  signup_enabled: true"
else
  echo -e "${YELLOW}  Login config returned HTTP $HTTP_CODE${NC}"
fi

# ── Step 7: Save output ──────────────────────────────────────────────

echo -e "${BLUE}Step 7: Saving output${NC}"

# Preserve raw responses from this run so callers can verify the
# server's view (canonicalized slugs, applied defaults, normalized
# fields). See SUGGESTIONS.md.
_safe_json() {
  printf '%s' "${1:-}" | jq -e . >/dev/null 2>&1 && printf '%s' "$1" || printf '{}'
}

RAW_ADMIN_LOGIN="$(_safe_json "${RESP_BODY:-}")"
# CREATE_RESP and PERM_RESP both include a trailing HTTP_CODE marker; strip it.
RAW_CONSUMER_ORG_CREATE="$(_safe_json "$(printf '%s' "${CREATE_RESP:-}" | grep -v 'HTTP_CODE' || true)")"
RAW_CONSUMER_LOGIN="$(_safe_json "${CON_LOGIN:-}")"
RAW_PERM_REGISTRY="$(_safe_json "$(printf '%s' "${PERM_RESP:-}" | grep -v 'HTTP_CODE' || true)")"
RAW_LOGIN_CONFIG_PUT="$(_safe_json "${LOGIN_CONFIG_PUT_BODY:-}")"

mkdir -p "$(dirname "$OUTPUT_FILE")"

jq -n \
  --arg org_id "$CONSUMER_ORG_ID" \
  --arg org_slug "$CONSUMER_ORG_SLUG" \
  --arg org_name "$CONSUMER_ORG_NAME" \
  --arg parent_org_id "$SERVICE_ORG_ID" \
  --arg parent_org_slug "$SERVICE_ORG_SLUG" \
  --arg default_role "$DEFAULT_ROLE" \
  --arg default_team_id "$DEFAULT_TEAM_ID" \
  --arg url "$AUTH_SERVICE_URL" \
  --arg reg_url "$AUTH_SERVICE_URL/organizations/$CONSUMER_ORG_SLUG/auth/register" \
  --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson tiers "$TIERS_JSON" \
  --argjson raw_admin_login "$RAW_ADMIN_LOGIN" \
  --argjson raw_consumer_org_create "$RAW_CONSUMER_ORG_CREATE" \
  --argjson raw_consumer_login "$RAW_CONSUMER_LOGIN" \
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
    tiers: $tiers,
    registration_endpoint: $reg_url,
    _meta: {
      auth_service_url: $url,
      created_at: $date,
      script: "08-setup-api-consumers.sh"
    },
    _raw: {
      admin_login: $raw_admin_login,
      consumer_org_create: $raw_consumer_org_create,
      consumer_login: $raw_consumer_login,
      permissions_registry_register: $raw_perm_registry,
      login_config_put: $raw_login_config_put
    }
  }' > "$OUTPUT_FILE"

chmod 600 "$OUTPUT_FILE" 2>/dev/null || true
echo -e "${GREEN}  Saved: $OUTPUT_FILE${NC}"

# ── Summary ───────────────────────────────────────────────────────────

echo ""
echo -e "${CYAN}=== API Consumer Org Setup Complete ===${NC}"
echo ""
echo "  $SERVICE_NAME ($SERVICE_ID)"
echo "  └── $CONSUMER_ORG_NAME ($CONSUMER_ORG_SLUG)"

for i in $(seq 0 $((TIER_COUNT - 1))); do
  T_NAME=$(jq -r ".tiers[$i].name" "$CONSUMERS_FILE")
  T_DEFAULT=$(jq -r ".tiers[$i].default" "$CONSUMERS_FILE")
  T_PERM_COUNT=$(jq ".tiers[$i].permissions | length" "$CONSUMERS_FILE")
  DEFAULT_MARKER=""
  if [ "$T_DEFAULT" = "true" ]; then DEFAULT_MARKER=" (DEFAULT — auto-join)"; fi
  echo "      ├── $T_NAME ($T_PERM_COUNT perms)$DEFAULT_MARKER"
done

echo "      └── login: default_role=$DEFAULT_ROLE, signup_enabled=true"
echo ""
echo "  Registration endpoint:"
echo "    $AUTH_SERVICE_URL/organizations/$CONSUMER_ORG_SLUG/auth/register"
echo ""
echo -e "${YELLOW}Consumer self-registration (two API calls):${NC}"
echo ""
echo "  # 1. Register"
echo "  curl -X POST $AUTH_SERVICE_URL/organizations/$CONSUMER_ORG_SLUG/auth/register \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"email\": \"my-svc@${SERVICE_ID}.consumers\", \"password\": \"...\"}'"
echo ""
echo "  # 2. Create API key"
echo "  curl -X POST $AUTH_SERVICE_URL/api-keys/ \\"
echo "    -H 'Authorization: Bearer \$TOKEN' \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"name\": \"my-svc-${SERVICE_ID}\", \"permissions\": [...]}'"
echo ""
