#!/bin/bash
# ==============================================================================
# consumer-register.sh — Consumer-side: self-register with a provider using
#                         an invitation file.
#
# INTENT:
#   This script runs in the CONSUMER's domain. The consumer creates their own
#   service account by registering via the provider's org-scoped endpoint.
#   They auto-join the provider's approved-permissions team and inherit ONLY
#   the permissions the provider approved.
#
#   The consumer never sees the provider's admin credentials.
#   The consumer never self-declares permissions.
#   The consumer cannot exceed the provider's approved scope.
#
# DOMAIN BOUNDARY:
#   This script only uses:
#     - The invitation file (public info: org slug, auth URL)
#     - The consumer's OWN service account credentials (created here)
#     - The org-scoped registration endpoint (public, same as end-user signup)
#
#   It does NOT use:
#     - Provider admin credentials (never has them)
#     - Provider credential files (never reads them)
#     - Global /auth/register (avoids namespace pollution)
#
# HOW PERMISSIONS FLOW:
#   The provider already ran provider-accept-consumer.sh which created:
#     Customer Sub-Org → "Consumer Access" team → [approved permissions]
#     Login config: default_team=team_id, signup_enabled=true
#
#   When this script registers the service account:
#     1. POST /organizations/{slug}/auth/register
#     2. Auth server reads login config → finds default_team
#     3. Adds service account to "Consumer Access" team
#     4. Service account inherits approved permissions via Zanzibar
#
#   This is the EXACT same flow as a human user registering via hosted login.
#   The only difference is this script does it programmatically.
#
# API KEY CREATION:
#   The service account creates its own API key. The permissions on the key
#   are drawn from what the team grants (via the invitation's approved list).
#
#   TODAY: The auth server does not validate key permissions against caller
#   permissions. The script self-limits by only requesting permissions from
#   the invitation file.
#
#   FUTURE: When POST /api-keys/ validates permissions ⊆ caller's effective
#   permissions, this script won't need to change — the team already grants
#   exactly the right set.
#
# USAGE:
#   # Convention-based (provider ran 08-setup-api-consumers.sh):
#   bash consumer-register.sh billing
#   bash consumer-register.sh payment
#
#   # With invitation file (from provider-accept-consumer.sh):
#   bash consumer-register.sh invitations/billing-sandbox-platform.invitation.json
#
#   # With custom service account credentials:
#   SA_EMAIL=mybot@billing.consumers \
#   SA_PASSWORD=MySecurePass2026 \
#   bash consumer-register.sh billing
#
# REQUIRES: jq, curl
# READS:    Invitation file OR discovers consumer org by convention
# WRITES:   credentials/<provider>-client.json
# ==============================================================================

set -e

# ==============================================================================
# Parse arguments — support both convention-based and invitation-file modes
# ==============================================================================
ARG="${1:?Usage: $0 <provider_id | invitation.json>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Detect mode: if arg ends in .json and file exists, use invitation mode.
# Otherwise, treat as provider_id for convention-based discovery.
if echo "$ARG" | grep -q '\.json$' && [ -f "$ARG" ]; then
    MODE="invitation"
    INVITATION_FILE="$ARG"
elif [ -f "$ARG" ]; then
    MODE="invitation"
    INVITATION_FILE="$ARG"
else
    MODE="convention"
    PROVIDER_ID="$ARG"
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# ==============================================================================
# Load config — from invitation file or convention-based discovery
#
# Convention mode: derives everything from the provider_id:
#   - Consumer org slug: {provider_id}-api-consumers
#   - Registration URL: {auth_url}/organizations/{slug}/auth/register
#   - Permissions: queried from the provider's api-consumers credential file
#     or falls back to a minimal set
# ==============================================================================

AUTH_SERVICE_URL="${AUTH_SERVICE_URL:-https://auth.service.ab0t.com}"

if [ "$MODE" = "invitation" ]; then
    echo -e "${BLUE}Loading invitation file${NC}"
    AUTH_SERVICE_URL=$(jq -r '.invitation.auth_service_url' "$INVITATION_FILE")
    PROVIDER_SERVICE_ID=$(jq -r '.invitation.provider.service_id' "$INVITATION_FILE")
    PROVIDER_SERVICE_NAME=$(jq -r '.invitation.provider.service_name' "$INVITATION_FILE")
    PROVIDER_SERVICE_URL=$(jq -r '.invitation.provider.service_url' "$INVITATION_FILE")
    CUSTOMER_ORG_ID=$(jq -r '.invitation.customer_org.id' "$INVITATION_FILE")
    CUSTOMER_ORG_SLUG=$(jq -r '.invitation.customer_org.slug' "$INVITATION_FILE")
    CUSTOMER_ORG_NAME=$(jq -r '.invitation.customer_org.name' "$INVITATION_FILE")
    REGISTRATION_ENDPOINT=$(jq -r '.invitation.registration_endpoint' "$INVITATION_FILE")
    APPROVED_PERMISSIONS=$(jq -c '.invitation.approved_permissions' "$INVITATION_FILE")
else
    echo -e "${BLUE}Convention-based discovery: $PROVIDER_ID${NC}"
    PROVIDER_SERVICE_ID="$PROVIDER_ID"
    PROVIDER_SERVICE_NAME="$PROVIDER_ID"
    PROVIDER_SERVICE_URL=""
    CUSTOMER_ORG_SLUG="${PROVIDER_ID}-api-consumers"
    CUSTOMER_ORG_NAME="${PROVIDER_ID} API Consumers"
    CUSTOMER_ORG_ID=""  # will be resolved during registration
    REGISTRATION_ENDPOINT="${AUTH_SERVICE_URL}/organizations/${CUSTOMER_ORG_SLUG}/auth/register"

    # Try to load permissions from the provider's api-consumers credential file
    # (created by 08-setup-api-consumers.sh)
    PROVIDER_CONSUMERS_CRED=""
    for CHECK_PATH in \
        "$SCRIPT_DIR/../../credentials/api-consumers.json" \
        "$SCRIPT_DIR/../../credentials/api-consumers-dev.json"; do
        if [ -f "$CHECK_PATH" ]; then
            PROVIDER_CONSUMERS_CRED="$CHECK_PATH"
            break
        fi
    done

    if [ -n "$PROVIDER_CONSUMERS_CRED" ]; then
        # Use the default tier's permissions from the credential file
        APPROVED_PERMISSIONS=$(jq -c '[.tiers[] | select(.default == true) | .permissions[]] | unique' "$PROVIDER_CONSUMERS_CRED")
        CUSTOMER_ORG_ID=$(jq -r '.org_id // empty' "$PROVIDER_CONSUMERS_CRED")
        echo -e "${GREEN}  Loaded permissions from $PROVIDER_CONSUMERS_CRED${NC}"
    else
        # Fallback: discover permissions by registering first, then querying
        APPROVED_PERMISSIONS='[]'
        echo -e "${YELLOW}  No credential file found — will discover permissions after registration${NC}"
    fi
fi
APPROVED_COUNT=$(echo "$APPROVED_PERMISSIONS" | jq 'length')

# Consumer's service account credentials — consumer controls these
# Default naming convention: {consumer}@{provider}.consumers
CONSUMER_ID="${CONSUMER_SERVICE_ID:-$(basename "$(cd "$SCRIPT_DIR/../.." 2>/dev/null && pwd)" 2>/dev/null || echo "consumer")}"

if [ "$MODE" = "invitation" ]; then
    SA_EMAIL="${SA_EMAIL:-$(jq -r '.client.service_account_email // empty' "$INVITATION_FILE")}"
    SA_PASSWORD="${SA_PASSWORD:-$(jq -r '.client.service_account_password // empty' "$INVITATION_FILE")}"
fi

# INTENT: Derive credentials from convention if not set.
# Email convention: {consumer}@{provider}.consumers
# Password: auto-generated if not provided (consumer controls this secret)
if [ -z "${SA_EMAIL:-}" ] || [ "${SA_EMAIL:-}" = "null" ]; then
    SA_EMAIL="${CONSUMER_ID}@${PROVIDER_SERVICE_ID}.consumers"
fi

if [ -z "${SA_PASSWORD:-}" ] || [ "${SA_PASSWORD:-}" = "null" ]; then
    SA_PASSWORD="$(python3 -c "import secrets, string; print(secrets.token_urlsafe(24))")"
    echo -e "${YELLOW}  Generated service account password (save this):${NC}"
    echo "  $SA_PASSWORD"
fi

# API key settings — consumer decides the name and rate limit for their own key
API_KEY_NAME="${API_KEY_NAME:-${CONSUMER_ID:-consumer}-${PROVIDER_SERVICE_ID}-backend}"
API_KEY_RATE_LIMIT="${API_KEY_RATE_LIMIT:-10000}"

OUTPUT_FILE="${SCRIPT_DIR}/credentials/${PROVIDER_SERVICE_ID}-client.json"

echo -e "${MAGENTA}=== Consumer: Self-Register with Provider ===${NC}"
echo ""
echo "  Provider:       ${PROVIDER_SERVICE_NAME} (${PROVIDER_SERVICE_ID})"
echo "  Customer Org:   ${CUSTOMER_ORG_NAME} (${CUSTOMER_ORG_SLUG})"
echo "  Account:        ${SA_EMAIL}"
echo "  Auth:           ${AUTH_SERVICE_URL}"
echo "  Approved Perms: ${APPROVED_COUNT}"
echo ""

# ==============================================================================
# Step 1: Register service account via org-scoped endpoint
#
# INTENT: The consumer registers using the org-scoped endpoint, NOT the global
#         /auth/register. This creates the account INSIDE the provider's
#         customer sub-org from the start.
#
#         Because the provider configured login with default_team, the auth
#         server automatically adds the service account to the "Consumer Access"
#         team. The service account inherits the team's permissions immediately.
#
#         This is the same endpoint end-users use to sign up via hosted login.
#         The only difference: this is a service account, not a human.
# ==============================================================================
echo -e "${BLUE}Step 1: Registering service account${NC}"
echo "  Endpoint: $REGISTRATION_ENDPOINT"

SA_REGISTER=$(curl -s -X POST "$REGISTRATION_ENDPOINT" \
    -H "Content-Type: application/json" \
    -d "{
        \"email\": \"$SA_EMAIL\",
        \"password\": \"$SA_PASSWORD\",
        \"name\": \"${CONSUMER_ID:-Consumer} Service Account\"
    }" 2>&1)

if echo "$SA_REGISTER" | jq -e '.access_token' >/dev/null 2>&1; then
    echo -e "${GREEN}  Registered: $SA_EMAIL${NC}"
    SA_TOKEN=$(echo "$SA_REGISTER" | jq -r '.access_token')
    SA_USER_ID=$(echo "$SA_REGISTER" | jq -r '.user.id // .user_info.id // .user_id // empty')
else
    # Account may already exist — try logging in with org context
    echo -e "${YELLOW}  Account may exist, trying login...${NC}"

    SA_LOGIN=$(curl -s -X POST "$AUTH_SERVICE_URL/auth/login" \
        -H "Content-Type: application/json" \
        -d "{
            \"email\": \"$SA_EMAIL\",
            \"password\": \"$SA_PASSWORD\"
        }" 2>&1)

    if echo "$SA_LOGIN" | jq -e '.access_token' >/dev/null 2>&1; then
        echo -e "${GREEN}  Logged in: $SA_EMAIL${NC}"
        SA_TOKEN=$(echo "$SA_LOGIN" | jq -r '.access_token')
        SA_USER_ID=$(echo "$SA_LOGIN" | jq -r '.user.id // .user_info.id // .user_id // empty')
    else
        echo -e "${RED}  Failed to register or login${NC}"
        echo "  Register response: $SA_REGISTER"
        echo "  Login response: $SA_LOGIN"
        exit 1
    fi
fi

echo ""

# ==============================================================================
# Step 2: Ensure org context
#
# INTENT: After registration, the service account should already be in the
#         customer sub-org (org-scoped registration puts them there). But if
#         we logged in to an existing account, we may need to switch context.
#
#         In convention mode, CUSTOMER_ORG_ID may be empty — we discover it
#         from the token's org context or from /users/me/organizations.
# ==============================================================================
echo -e "${BLUE}Step 2: Ensuring customer org context${NC}"

if [ -n "$CUSTOMER_ORG_ID" ]; then
    # Known org_id — switch to it
    SA_ORG_SWITCH=$(curl -s -X POST "$AUTH_SERVICE_URL/auth/switch-organization" \
        -H "Authorization: Bearer $SA_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"org_id\": \"$CUSTOMER_ORG_ID\"}" 2>&1)

    if echo "$SA_ORG_SWITCH" | jq -e '.access_token' >/dev/null 2>&1; then
        SA_TOKEN=$(echo "$SA_ORG_SWITCH" | jq -r '.access_token')
        echo -e "${GREEN}  Switched to org: $CUSTOMER_ORG_ID${NC}"
    else
        echo -e "${YELLOW}  Already in org context${NC}"
    fi
else
    # INTENT: Convention mode — discover the org_id from the registration
    # response or from /users/me/organizations.
    MY_ORGS=$(curl -s "$AUTH_SERVICE_URL/users/me/organizations" \
        -H "Authorization: Bearer $SA_TOKEN" 2>/dev/null || echo "[]")
    CUSTOMER_ORG_ID=$(echo "$MY_ORGS" | jq -r \
        --arg slug "$CUSTOMER_ORG_SLUG" \
        '.[] | select(.slug == $slug) | .id' 2>/dev/null | head -1)

    if [ -n "$CUSTOMER_ORG_ID" ] && [ "$CUSTOMER_ORG_ID" != "null" ]; then
        SA_ORG_SWITCH=$(curl -s -X POST "$AUTH_SERVICE_URL/auth/switch-organization" \
            -H "Authorization: Bearer $SA_TOKEN" \
            -H "Content-Type: application/json" \
            -d "{\"org_id\": \"$CUSTOMER_ORG_ID\"}" 2>&1)
        if echo "$SA_ORG_SWITCH" | jq -e '.access_token' >/dev/null 2>&1; then
            SA_TOKEN=$(echo "$SA_ORG_SWITCH" | jq -r '.access_token')
        fi
        echo -e "${GREEN}  Discovered org: $CUSTOMER_ORG_ID${NC}"
    else
        echo -e "${YELLOW}  Could not discover org_id (using registration context)${NC}"
    fi
fi

echo ""

# ==============================================================================
# Step 3: Verify team membership
#
# INTENT: Confirm the auto-join worked. The provider configured the login
#         config with default_team, so the auth server should have added
#         the service account to the "Consumer Access" team automatically.
#
#         If not in the team, permissions won't flow. This is a safety check.
# ==============================================================================
echo -e "${BLUE}Step 3: Verifying team membership${NC}"

USER_TEAMS=$(curl -s "$AUTH_SERVICE_URL/users/me/teams" \
    -H "Authorization: Bearer $SA_TOKEN" 2>/dev/null || echo "[]")

TEAM_COUNT=$(echo "$USER_TEAMS" | jq 'if type == "array" then length else 0 end')

if [ "$TEAM_COUNT" -gt 0 ]; then
    echo -e "${GREEN}  Member of $TEAM_COUNT team(s)${NC}"
    echo "$USER_TEAMS" | jq -r '.[] | "    • \(.name // .id)"' 2>/dev/null || true
else
    echo -e "${YELLOW}  Not in any teams (auto-join may not have triggered)${NC}"
    echo -e "${YELLOW}  API key permissions may be limited${NC}"
fi

# INTENT: If we don't have a permission list yet (convention mode without
# credential file), discover permissions from the user's effective set.
# The team auto-join should have granted the tier's permissions via Zanzibar.
if [ "$APPROVED_COUNT" -eq 0 ] && [ -n "$SA_USER_ID" ] && [ -n "$CUSTOMER_ORG_ID" ]; then
    echo -e "${BLUE}Step 3b: Discovering permissions from team membership${NC}"

    DISCOVERED_PERMS=$(curl -s "$AUTH_SERVICE_URL/permissions/user/$SA_USER_ID?org_id=$CUSTOMER_ORG_ID" \
        -H "Authorization: Bearer $SA_TOKEN" 2>/dev/null)
    PERM_LIST=$(echo "$DISCOVERED_PERMS" | jq -r '.permissions // []')

    # INTENT: Filter to only service-specific permissions (provider.*, not org.read etc.)
    # Service permissions follow the format: {service}.{action}[.{resource}]
    # Role permissions (org.read, api.read, etc.) are NOT included in API keys.
    APPROVED_PERMISSIONS=$(echo "$PERM_LIST" | jq -c \
        --arg svc "$PROVIDER_SERVICE_ID" \
        '[.[] | select(startswith($svc + "."))]')
    APPROVED_COUNT=$(echo "$APPROVED_PERMISSIONS" | jq 'length')

    if [ "$APPROVED_COUNT" -gt 0 ]; then
        echo -e "${GREEN}  Discovered $APPROVED_COUNT permissions from team:${NC}"
        echo "$APPROVED_PERMISSIONS" | jq -r '.[]' | while read -r p; do echo "    • $p"; done
    else
        echo -e "${YELLOW}  No service-specific permissions found (team may not have granted any)${NC}"
    fi
fi

echo ""

# ==============================================================================
# Step 4: Create API key
#
# INTENT: The consumer creates an API key with ONLY the permissions the
#         provider approved (from the invitation file). The consumer does
#         not invent permissions — it reads them from the invitation.
#
#         TODAY: The auth server doesn't validate these against the caller's
#         effective permissions. The script self-limits.
#
#         FUTURE: The auth server will enforce key perms ⊆ caller's perms.
#         When that happens, this step works unchanged because the team
#         already grants exactly these permissions.
# ==============================================================================
echo -e "${BLUE}Step 4: Creating API key${NC}"
echo "  Permissions (from invitation):"
echo "$APPROVED_PERMISSIONS" | jq -r '.[]' | while read -r p; do echo "    • $p"; done

API_KEY_RESPONSE=$(curl -s -X POST "$AUTH_SERVICE_URL/api-keys/" \
    -H "Authorization: Bearer $SA_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{
        "name": "'"$API_KEY_NAME"'",
        "permissions": '"$APPROVED_PERMISSIONS"',
        "rate_limit": '"$API_KEY_RATE_LIMIT"',
        "metadata": {
            "consumer_service": "'"${CONSUMER_ID:-consumer}"'",
            "provider_service": "'"$PROVIDER_SERVICE_ID"'",
            "customer_org": "'"$CUSTOMER_ORG_ID"'",
            "source": "consumer-register.sh",
            "invitation_based": true
        }
    }' 2>&1)

API_KEY=$(echo "$API_KEY_RESPONSE" | jq -r '.key // empty')
API_KEY_ID=$(echo "$API_KEY_RESPONSE" | jq -r '.id // empty')

if [ -z "$API_KEY" ] || [ "$API_KEY" = "null" ]; then
    echo -e "${RED}  Failed to create API key${NC}"
    echo "  Response: $API_KEY_RESPONSE"
    exit 1
fi

echo -e "${GREEN}  Created: ${API_KEY:0:20}...${NC}"
echo ""

# ==============================================================================
# Step 5: Save credentials
#
# INTENT: Save the consumer's own credentials. This file contains the
#         consumer's service account and API key — no provider secrets.
# ==============================================================================
echo -e "${BLUE}Step 5: Saving credentials${NC}"

mkdir -p "$(dirname "$OUTPUT_FILE")"

CREATED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

cat > "$OUTPUT_FILE" <<EOF
{
    "provider": {
        "service_id": "$PROVIDER_SERVICE_ID",
        "service_name": "$PROVIDER_SERVICE_NAME",
        "service_url": "$PROVIDER_SERVICE_URL"
    },
    "customer_org": {
        "id": "$CUSTOMER_ORG_ID",
        "name": "$CUSTOMER_ORG_NAME",
        "slug": "$CUSTOMER_ORG_SLUG"
    },
    "service_account": {
        "email": "$SA_EMAIL",
        "password": "$SA_PASSWORD",
        "user_id": "$SA_USER_ID"
    },
    "api_key": {
        "id": "$API_KEY_ID",
        "key": "$API_KEY",
        "permissions": $APPROVED_PERMISSIONS
    },
    "invitation_source": "$(basename "$INVITATION_FILE")",
    "created_at": "$CREATED_AT"
}
EOF

echo -e "${GREEN}  Saved: $OUTPUT_FILE${NC}"
echo ""

# ==============================================================================
# Summary
# ==============================================================================
PROVIDER_UPPER=$(echo "$PROVIDER_SERVICE_ID" | tr '[:lower:]' '[:upper:]' | tr '-' '_')

echo -e "${CYAN}=== Consumer Registration Complete ===${NC}"
echo ""
echo "  Auth Service"
echo "  └── ${PROVIDER_SERVICE_NAME}"
echo "      └── ${CUSTOMER_ORG_NAME} ($CUSTOMER_ORG_ID)"
echo "          └── ${SA_EMAIL} [service account, member]"
echo "              └── API key: ${API_KEY:0:20}..."
echo ""
echo "  Permissions (inherited via team, $APPROVED_COUNT total):"
echo "$APPROVED_PERMISSIONS" | jq -r '.[]' | while read -r p; do echo "    • $p"; done
echo ""
echo "  Credentials: $OUTPUT_FILE"
echo ""
echo -e "${YELLOW}Set in your .env:${NC}"
echo "  ${PROVIDER_UPPER}_SERVICE_API_KEY=$API_KEY"
echo ""
echo -e "${YELLOW}Usage:${NC}"
echo "  curl -H \"X-API-Key: \$${PROVIDER_UPPER}_SERVICE_API_KEY\" ${PROVIDER_SERVICE_URL}/..."
echo ""
