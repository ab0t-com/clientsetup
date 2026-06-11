#!/bin/bash
# ==============================================================================
# register-as-client.sh — Register a service as a client of another service
#
# INTENT:
#   CO-LOCATED REGISTRATION ENGINE. Use when the consumer and provider run
#   on the same machine and the consumer has access to the provider's
#   credential files. This is a shortcut for single-operator deployments.
#
#   For multi-team deployments where the consumer does NOT have access to
#   the provider's credentials, use consumer-register.sh instead (which
#   uses org-scoped self-registration via the provider's consumer org).
#
# HOW IT WORKS:
#   1. Reads a client config (clients.d/<provider>.json) that declares what
#      permissions the client needs from the provider.
#   2. Loads the provider's credentials (admin email/password, org ID) from
#      the provider's own credentials file.
#   3. Logs in as the provider admin and creates:
#      a) A customer sub-org under the provider's root org
#      b) A service account for the client in that sub-org
#      c) An API key with the requested permissions
#   4. Saves structured output to credentials/<provider>-client.json
#
# The client service never accesses the provider's internals directly.
# All work is done through the auth service using the provider admin's
# credentials — the same flow as if the provider admin did it manually.
#
# IDEMPOTENT: Safe to run multiple times.
#   - Existing orgs, accounts, and memberships are detected and reused.
#   - A new API key is created each run (old keys remain valid).
#
# USAGE:
#   ./register-as-client.sh billing          # Register with billing service
#   ./register-as-client.sh payment          # Register with payment service
#   PROVIDER_CREDS=/path/to/creds.json ./register-as-client.sh billing
#
# REQUIRES: jq, curl
# READS:    clients.d/<provider>.json (client config)
# READS:    Provider's credentials file (path from config or PROVIDER_CREDS env)
# WRITES:   credentials/<provider>-client.json
# ==============================================================================

set -e

# ==============================================================================
# Parse arguments
# ==============================================================================
PROVIDER_ID="${1:?Usage: $0 <provider_id> (e.g. billing, payment)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/clients.d/${PROVIDER_ID}.json"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Client config not found: $CONFIG_FILE"
    echo "Create clients.d/${PROVIDER_ID}.json first."
    exit 1
fi

AUTH_SERVICE_URL="${AUTH_SERVICE_URL:-http://localhost:8001}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# ==============================================================================
# Load config
# ==============================================================================
PROVIDER_SERVICE_ID=$(jq -r '.provider.service_id' "$CONFIG_FILE")
PROVIDER_SERVICE_NAME=$(jq -r '.provider.service_name' "$CONFIG_FILE")
PROVIDER_SERVICE_URL=$(jq -r '.provider.service_url' "$CONFIG_FILE")

CLIENT_SERVICE_ID=$(jq -r '.client.service_id' "$CONFIG_FILE")
CLIENT_SERVICE_NAME=$(jq -r '.client.service_name' "$CONFIG_FILE")
CUSTOMER_ORG_NAME=$(jq -r '.client.customer_org_name' "$CONFIG_FILE")
CUSTOMER_ORG_SLUG=$(jq -r '.client.customer_org_slug' "$CONFIG_FILE")
SA_EMAIL=$(jq -r '.client.service_account_email' "$CONFIG_FILE")
SA_PASSWORD=$(jq -r '.client.service_account_password' "$CONFIG_FILE")

API_KEY_NAME=$(jq -r '.api_key.name' "$CONFIG_FILE")
API_KEY_RATE_LIMIT=$(jq -r '.api_key.rate_limit' "$CONFIG_FILE")
API_KEY_PURPOSE=$(jq -r '.api_key.metadata_purpose' "$CONFIG_FILE")
PERMISSIONS_JSON=$(jq -c '.permissions' "$CONFIG_FILE")

OUTPUT_FILE="${SCRIPT_DIR}/credentials/${PROVIDER_ID}-client.json"

echo -e "${MAGENTA}=== Service Client Registration ===${NC}"
echo ""
echo "  Client:   ${CLIENT_SERVICE_NAME} (${CLIENT_SERVICE_ID})"
echo "  Provider: ${PROVIDER_SERVICE_NAME} (${PROVIDER_SERVICE_ID})"
echo "  Auth:     ${AUTH_SERVICE_URL}"
echo ""

# ==============================================================================
# Step 1: Load provider credentials
# ==============================================================================
echo -e "${BLUE}Step 1: Loading provider credentials${NC}"

# Resolve provider credentials path
if [ -n "$PROVIDER_CREDS" ] && [ -f "$PROVIDER_CREDS" ]; then
    PROVIDER_CREDS_FILE="$PROVIDER_CREDS"
else
    # Use path from config (absolute path)
    PROVIDER_CREDS_FILE=$(jq -r '.provider.credentials_path' "$CONFIG_FILE")
fi

if [ ! -f "$PROVIDER_CREDS_FILE" ]; then
    echo -e "${RED}Provider credentials not found: $PROVIDER_CREDS_FILE${NC}"
    echo ""
    echo "The provider service must have run its own register-service-permissions.sh"
    echo "to create its credentials file before clients can register."
    echo ""
    echo "Either:"
    echo "  1. Run the provider's registration:  cd <provider>/output && ./register-service-permissions.sh"
    echo "  2. Or set PROVIDER_CREDS=/path/to/provider-creds.json"
    exit 1
fi

PROVIDER_ADMIN_EMAIL=$(jq -r '.admin.email' "$PROVIDER_CREDS_FILE")
PROVIDER_ADMIN_PASSWORD=$(jq -r '.admin.password' "$PROVIDER_CREDS_FILE")
PROVIDER_ORG_ID=$(jq -r '.organization.id' "$PROVIDER_CREDS_FILE")

if [ -z "$PROVIDER_ORG_ID" ] || [ "$PROVIDER_ORG_ID" = "null" ]; then
    echo -e "${RED}Provider credentials missing organization ID${NC}"
    exit 1
fi

echo -e "${GREEN}  Loaded: $PROVIDER_CREDS_FILE${NC}"
echo "  Provider org: $PROVIDER_ORG_ID"
echo "  Provider admin: $PROVIDER_ADMIN_EMAIL"
echo ""

# ==============================================================================
# Step 2: Login as provider admin
# ==============================================================================
echo -e "${BLUE}Step 2: Logging in as provider admin${NC}"

PROVIDER_LOGIN=$(curl -s -X POST "$AUTH_SERVICE_URL/auth/login" \
    -H "Content-Type: application/json" \
    -d "{
        \"email\": \"$PROVIDER_ADMIN_EMAIL\",
        \"password\": \"$PROVIDER_ADMIN_PASSWORD\"
    }" 2>&1)

if ! echo "$PROVIDER_LOGIN" | jq -e '.access_token' >/dev/null 2>&1; then
    echo -e "${RED}Failed to login as provider admin${NC}"
    echo "Response: $PROVIDER_LOGIN"
    exit 1
fi

BOOTSTRAP_TOKEN=$(echo "$PROVIDER_LOGIN" | jq -r '.access_token')

# Switch to the provider org context
SWITCH_RESPONSE=$(curl -s -X POST "$AUTH_SERVICE_URL/auth/switch-organization" \
    -H "Authorization: Bearer $BOOTSTRAP_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"org_id\": \"$PROVIDER_ORG_ID\"}" 2>&1)

if echo "$SWITCH_RESPONSE" | jq -e '.access_token' >/dev/null 2>&1; then
    PROVIDER_TOKEN=$(echo "$SWITCH_RESPONSE" | jq -r '.access_token')
    echo -e "${GREEN}  Logged in (switched to org: $PROVIDER_ORG_ID)${NC}"
else
    echo -e "${YELLOW}  Switch-org failed, using bootstrap token${NC}"
    PROVIDER_TOKEN="$BOOTSTRAP_TOKEN"
fi

echo ""

# ==============================================================================
# Step 3: Find or create customer sub-org under provider
# ==============================================================================
echo -e "${BLUE}Step 3: Finding/creating customer sub-org${NC}"

# Check if customer org already exists
PROVIDER_ORGS=$(curl -s -X GET "$AUTH_SERVICE_URL/users/me/organizations" \
    -H "Authorization: Bearer $PROVIDER_TOKEN" 2>&1)

CUSTOMER_ORG_ID=$(echo "$PROVIDER_ORGS" | jq -r \
    --arg name "$CUSTOMER_ORG_NAME" \
    '.[] | select(.name == $name) | .id' 2>/dev/null | head -1)

if [ -n "$CUSTOMER_ORG_ID" ] && [ "$CUSTOMER_ORG_ID" != "null" ] && [ "$CUSTOMER_ORG_ID" != "" ]; then
    echo -e "${GREEN}  Found existing: $CUSTOMER_ORG_ID ($CUSTOMER_ORG_SLUG)${NC}"
else
    echo "  Creating sub-org: $CUSTOMER_ORG_NAME"

    CREATE_ORG_RESPONSE=$(curl -s -X POST "$AUTH_SERVICE_URL/organizations/" \
        -H "Authorization: Bearer $PROVIDER_TOKEN" \
        -H "Content-Type: application/json" \
        -d '{
            "name": "'"$CUSTOMER_ORG_NAME"'",
            "slug": "'"$CUSTOMER_ORG_SLUG"'",
            "parent_id": "'"$PROVIDER_ORG_ID"'",
            "billing_type": "enterprise",
            "settings": {
                "type": "customer_account",
                "parent_service": "'"$PROVIDER_SERVICE_ID"'",
                "customer_service_id": "'"$CLIENT_SERVICE_ID"'",
                "customer_name": "'"$CLIENT_SERVICE_NAME"'"
            }
        }' 2>&1)

    CUSTOMER_ORG_ID=$(echo "$CREATE_ORG_RESPONSE" | jq -r '.id // empty')

    if [ -z "$CUSTOMER_ORG_ID" ] || [ "$CUSTOMER_ORG_ID" = "null" ]; then
        echo -e "${RED}  Failed to create customer sub-org${NC}"
        echo "  Response: $CREATE_ORG_RESPONSE"
        exit 1
    fi

    echo -e "${GREEN}  Created: $CUSTOMER_ORG_ID${NC}"
fi

echo ""

# ==============================================================================
# Step 4: Create or find service account
# ==============================================================================
echo -e "${BLUE}Step 4: Setting up service account${NC}"

# Try to register (idempotent: may already exist)
SA_REGISTER=$(curl -s -X POST "$AUTH_SERVICE_URL/auth/register" \
    -H "Content-Type: application/json" \
    -d "{
        \"email\": \"$SA_EMAIL\",
        \"password\": \"$SA_PASSWORD\",
        \"name\": \"$CLIENT_SERVICE_NAME Service Account\"
    }" 2>&1)

if echo "$SA_REGISTER" | jq -e '.access_token' >/dev/null 2>&1; then
    echo -e "${GREEN}  Created service account: $SA_EMAIL${NC}"
    SA_USER_ID=$(echo "$SA_REGISTER" | jq -r '.user.id // .user_info.id // .user_id // empty')
else
    # Already exists — login to verify
    SA_LOGIN=$(curl -s -X POST "$AUTH_SERVICE_URL/auth/login" \
        -H "Content-Type: application/json" \
        -d "{
            \"email\": \"$SA_EMAIL\",
            \"password\": \"$SA_PASSWORD\"
        }" 2>&1)

    if echo "$SA_LOGIN" | jq -e '.access_token' >/dev/null 2>&1; then
        echo -e "${GREEN}  Service account exists: $SA_EMAIL${NC}"
        SA_USER_ID=$(echo "$SA_LOGIN" | jq -r '.user.id // .user_info.id // .user_id // empty')
    else
        echo -e "${RED}  Failed to create or login service account${NC}"
        echo "  Register: $SA_REGISTER"
        echo "  Login: $SA_LOGIN"
        exit 1
    fi
fi

echo ""

# ==============================================================================
# Step 5: Add service account to customer org
# ==============================================================================
echo -e "${BLUE}Step 5: Adding service account to customer org${NC}"

# Switch provider admin to customer org context
PROVIDER_CONTEXT_SWITCH=$(curl -s -X POST "$AUTH_SERVICE_URL/auth/switch-organization" \
    -H "Authorization: Bearer $PROVIDER_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"org_id\": \"$CUSTOMER_ORG_ID\"}" 2>&1)

PROVIDER_CONTEXT_TOKEN=$(echo "$PROVIDER_CONTEXT_SWITCH" | jq -r '.access_token // empty')

if [ -z "$PROVIDER_CONTEXT_TOKEN" ]; then
    echo -e "${RED}  Failed to login with customer org context${NC}"
    echo "  Response: $PROVIDER_CONTEXT_LOGIN"
    exit 1
fi

# Invite service account to customer org
INVITE_RESPONSE=$(curl -s -X POST "$AUTH_SERVICE_URL/organizations/$CUSTOMER_ORG_ID/invite" \
    -H "Authorization: Bearer $PROVIDER_CONTEXT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{
        \"email\": \"$SA_EMAIL\",
        \"role\": \"admin\"
    }" 2>&1)

if echo "$INVITE_RESPONSE" | jq -e '.user_id' >/dev/null 2>&1; then
    echo -e "${GREEN}  Added to org${NC}"
else
    echo -e "${YELLOW}  Already a member (or invite pending)${NC}"
fi

echo ""

# ==============================================================================
# Step 6: Login service account with org context
# ==============================================================================
echo -e "${BLUE}Step 6: Getting service account org-scoped token${NC}"

# First login the service account to get a bootstrap token
SA_LOGIN_BOOTSTRAP=$(curl -s -X POST "$AUTH_SERVICE_URL/auth/login" \
    -H "Content-Type: application/json" \
    -d "{
        \"email\": \"$SA_EMAIL\",
        \"password\": \"$SA_PASSWORD\"
    }" 2>&1)

SA_BOOTSTRAP_TOKEN=$(echo "$SA_LOGIN_BOOTSTRAP" | jq -r '.access_token // empty')

if [ -z "$SA_BOOTSTRAP_TOKEN" ]; then
    echo -e "${RED}  Failed to login service account${NC}"
    echo "  Response: $SA_LOGIN_BOOTSTRAP"
    exit 1
fi

# Switch to customer org context
SA_ORG_SWITCH=$(curl -s -X POST "$AUTH_SERVICE_URL/auth/switch-organization" \
    -H "Authorization: Bearer $SA_BOOTSTRAP_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"org_id\": \"$CUSTOMER_ORG_ID\"}" 2>&1)

SA_ORG_TOKEN=$(echo "$SA_ORG_SWITCH" | jq -r '.access_token // empty')

if [ -z "$SA_ORG_TOKEN" ]; then
    echo -e "${RED}  Failed to switch service account to customer org${NC}"
    echo "  Response: $SA_ORG_SWITCH"
    exit 1
fi

echo -e "${GREEN}  Got org-scoped token${NC}"
echo ""

# ==============================================================================
# Step 7: Create API key
# ==============================================================================
echo -e "${BLUE}Step 7: Creating API key${NC}"
echo "  Permissions: $(echo "$PERMISSIONS_JSON" | jq -r '.[]' | tr '\n' ', ' | sed 's/,$//')"

API_KEY_RESPONSE=$(curl -s -X POST "$AUTH_SERVICE_URL/api-keys/" \
    -H "Authorization: Bearer $SA_ORG_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{
        "name": "'"$API_KEY_NAME"'",
        "permissions": '"$PERMISSIONS_JSON"',
        "rate_limit": '"$API_KEY_RATE_LIMIT"',
        "metadata": {
            "client_service": "'"$CLIENT_SERVICE_ID"'",
            "provider_service": "'"$PROVIDER_SERVICE_ID"'",
            "customer_org": "'"$CUSTOMER_ORG_ID"'",
            "purpose": "'"$API_KEY_PURPOSE"'"
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
# Step 8: Save credentials
# ==============================================================================
echo -e "${BLUE}Step 8: Saving credentials${NC}"

mkdir -p "$(dirname "$OUTPUT_FILE")"

CREATED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

cat > "$OUTPUT_FILE" <<EOF
{
    "provider": {
        "service_id": "$PROVIDER_SERVICE_ID",
        "service_name": "$PROVIDER_SERVICE_NAME",
        "service_url": "$PROVIDER_SERVICE_URL",
        "root_org_id": "$PROVIDER_ORG_ID"
    },
    "customer_org": {
        "id": "$CUSTOMER_ORG_ID",
        "name": "$CUSTOMER_ORG_NAME",
        "slug": "$CUSTOMER_ORG_SLUG",
        "parent_org": "$PROVIDER_ORG_ID"
    },
    "service_account": {
        "email": "$SA_EMAIL",
        "password": "$SA_PASSWORD",
        "user_id": "$SA_USER_ID"
    },
    "api_key": {
        "id": "$API_KEY_ID",
        "key": "$API_KEY",
        "permissions": $PERMISSIONS_JSON
    },
    "created_at": "$CREATED_AT"
}
EOF

echo -e "${GREEN}  Saved: $OUTPUT_FILE${NC}"
echo ""

# ==============================================================================
# Summary
# ==============================================================================
echo -e "${CYAN}=== Registration Complete ===${NC}"
echo ""
echo "  Auth Service"
echo "  └── ${PROVIDER_SERVICE_NAME} ($PROVIDER_ORG_ID)"
echo "      └── ${CUSTOMER_ORG_NAME} ($CUSTOMER_ORG_ID)"
echo "          └── ${SA_EMAIL} [service account]"
echo "              └── API key: ${API_KEY:0:20}..."
echo ""
echo "Permissions granted:"
echo "$PERMISSIONS_JSON" | jq -r '.[]' | while read -r p; do echo "  • $p"; done
echo ""
echo "Credentials: $OUTPUT_FILE"
echo ""
echo -e "${YELLOW}Usage in ${CLIENT_SERVICE_NAME}:${NC}"
echo "  API_KEY=\$(jq -r '.api_key.key' $OUTPUT_FILE)"
echo "  curl -H \"X-API-Key: \$API_KEY\" ${PROVIDER_SERVICE_URL}/billing/..."
