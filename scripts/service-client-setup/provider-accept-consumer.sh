#!/bin/bash
# ==============================================================================
# provider-accept-consumer.sh — Provider-side: prepare a customer sub-org for a
#                                consumer service.
#
# INTENT:
#   This script runs in the PROVIDER's domain. Only the provider admin should
#   run it. It creates the sub-org, registers the APPROVED permissions, creates
#   an auto-join team, and configures login — exactly the same pattern as
#   04-setup-default-team.sh does for end-users.
#
#   The output is an INVITATION FILE that the consumer uses to self-register.
#   The consumer never sees the provider's admin credentials.
#
# DOMAIN BOUNDARY:
#   ┌──────────────────────────────────────────────────────────┐
#   │  PROVIDER SIDE (this script)                             │
#   │                                                          │
#   │  Provider admin logs in with OWN credentials             │
#   │  Creates customer sub-org under OWN org                  │
#   │  Registers APPROVED permissions (provider decides scope) │
#   │  Creates team with those permissions                     │
#   │  Configures login so consumer auto-joins team            │
#   │  Outputs invitation file (org slug + auth URL only)      │
#   │                                                          │
#   └──────────────────────┬───────────────────────────────────┘
#                          │ invitation.json (no secrets)
#                          ▼
#   ┌──────────────────────────────────────────────────────────┐
#   │  CONSUMER SIDE (consumer-register.sh)                    │
#   │                                                          │
#   │  Reads invitation file                                   │
#   │  Self-registers via org-scoped endpoint                  │
#   │  Auto-joins team → inherits ONLY approved permissions    │
#   │  Creates API key (server validates: key perms ⊆ caller)  │
#   │                                                          │
#   └──────────────────────────────────────────────────────────┘
#
# ANALOGY:
#   This is the provider-side equivalent of 04-setup-default-team.sh.
#   Step 04 creates an end-users org where HUMANS self-register.
#   This script creates a customer org where SERVICES self-register.
#   Same Zanzibar pattern: org → team → permissions → auto-join.
#
# WHAT IT CREATES IN AUTH:
#   Provider Org (billing)
#   └── Customer Sub-Org (Sandbox Platform - Billing Customer)
#       ├── "Consumer Access" team
#       │     └── permissions: [billing.read, billing.read.accounts, ...]
#       └── login config: default_team=team_id, default_role=member
#           → service accounts that register here auto-join the team
#           → they inherit ONLY the permissions the provider approved
#
# IDEMPOTENT: Safe to run multiple times.
#   - Existing orgs and teams are detected and reused.
#   - Login config is re-applied (full replace).
#
# USAGE:
#   # Run by the provider (e.g., billing team):
#   cd /path/to/billing/output
#   bash provider-accept-consumer.sh consumers.d/sandbox-platform.json
#
#   # Or from the consumer's setup dir (co-located deployment):
#   bash provider-accept-consumer.sh clients.d/billing.json
#
# REQUIRES: jq, curl
# READS:    Consumer config file (clients.d/<provider>.json or consumers.d/<consumer>.json)
# READS:    Provider credentials (from config → provider.credentials_path)
# WRITES:   invitations/<provider>-<consumer>.invitation.json
# ==============================================================================

set -e

# ==============================================================================
# Parse arguments
# ==============================================================================
CONFIG_FILE="${1:?Usage: $0 <config.json> (e.g. clients.d/billing.json)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Config not found: $CONFIG_FILE"
    exit 1
fi

AUTH_SERVICE_URL="${AUTH_SERVICE_URL:-https://auth.service.ab0t.com}"

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

# IMPORTANT: The provider decides which permissions to approve.
# This list comes from the config, but in a multi-team setup the provider
# would review and approve it before running this script.
PERMISSIONS_JSON=$(jq -c '.permissions' "$CONFIG_FILE")
PERMISSION_COUNT=$(echo "$PERMISSIONS_JSON" | jq 'length')

CONSUMER_TEAM_NAME="${CONSUMER_TEAM_NAME:-Consumer Access}"
INVITATION_DIR="${SCRIPT_DIR}/invitations"
INVITATION_FILE="${INVITATION_DIR}/${PROVIDER_SERVICE_ID}-${CLIENT_SERVICE_ID}.invitation.json"

echo -e "${MAGENTA}=== Provider: Accept Consumer ===${NC}"
echo ""
echo "  Provider:  ${PROVIDER_SERVICE_NAME} (${PROVIDER_SERVICE_ID})"
echo "  Consumer:  ${CLIENT_SERVICE_NAME} (${CLIENT_SERVICE_ID})"
echo "  Sub-Org:   ${CUSTOMER_ORG_NAME}"
echo "  Team:      ${CONSUMER_TEAM_NAME}"
echo "  Approved:  ${PERMISSION_COUNT} permissions"
echo "  Auth:      ${AUTH_SERVICE_URL}"
echo ""

# ==============================================================================
# Step 1: Load provider credentials and login
#
# INTENT: The provider admin authenticates with THEIR OWN credentials.
#         This script never touches or needs the consumer's credentials.
# ==============================================================================
echo -e "${BLUE}Step 1: Loading provider credentials${NC}"

PROVIDER_CREDS_FILE="${PROVIDER_CREDS:-$(jq -r '.provider.credentials_path' "$CONFIG_FILE")}"

if [ ! -f "$PROVIDER_CREDS_FILE" ]; then
    echo -e "${RED}Provider credentials not found: $PROVIDER_CREDS_FILE${NC}"
    echo ""
    echo "The provider must have run register-service-permissions.sh first."
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

echo -e "${BLUE}  Logging in as provider admin${NC}"

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

# Switch to provider org context
SWITCH_RESPONSE=$(curl -s -X POST "$AUTH_SERVICE_URL/auth/switch-organization" \
    -H "Authorization: Bearer $BOOTSTRAP_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"org_id\": \"$PROVIDER_ORG_ID\"}" 2>&1)

if echo "$SWITCH_RESPONSE" | jq -e '.access_token' >/dev/null 2>&1; then
    PROVIDER_TOKEN=$(echo "$SWITCH_RESPONSE" | jq -r '.access_token')
    echo -e "${GREEN}  Logged in (org: $PROVIDER_ORG_ID)${NC}"
else
    PROVIDER_TOKEN="$BOOTSTRAP_TOKEN"
    echo -e "${YELLOW}  Switch-org failed, using bootstrap token${NC}"
fi

echo ""

# ==============================================================================
# Step 2: Find or create customer sub-org
#
# INTENT: The provider creates a child org under their own org tree.
#         This sub-org is where the consumer's service account will live.
#         The provider retains full control (parent org relationship).
# ==============================================================================
echo -e "${BLUE}Step 2: Finding/creating customer sub-org${NC}"

PROVIDER_ORGS=$(curl -s -X GET "$AUTH_SERVICE_URL/users/me/organizations" \
    -H "Authorization: Bearer $PROVIDER_TOKEN" 2>&1)

CUSTOMER_ORG_ID=$(echo "$PROVIDER_ORGS" | jq -r \
    --arg name "$CUSTOMER_ORG_NAME" \
    '.[] | select(.name == $name) | .id' 2>/dev/null | head -1)

if [ -n "$CUSTOMER_ORG_ID" ] && [ "$CUSTOMER_ORG_ID" != "null" ] && [ "$CUSTOMER_ORG_ID" != "" ]; then
    echo -e "${GREEN}  Found existing: $CUSTOMER_ORG_ID${NC}"
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
    echo -e "${GREEN}  Zanzibar parent relationship auto-created: ${PROVIDER_SERVICE_ID} → ${CUSTOMER_ORG_SLUG}${NC}"
fi

echo ""

# ==============================================================================
# Step 3: Switch to customer sub-org context
#
# INTENT: Provider admin operates within the sub-org to set up team and
#         login config. This is the same pattern as step 04's end-users setup.
# ==============================================================================
echo -e "${BLUE}Step 3: Switching to customer sub-org context${NC}"

CUSTOMER_CONTEXT=$(curl -s -X POST "$AUTH_SERVICE_URL/auth/switch-organization" \
    -H "Authorization: Bearer $PROVIDER_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"org_id\": \"$CUSTOMER_ORG_ID\"}" 2>&1)

CUSTOMER_TOKEN=$(echo "$CUSTOMER_CONTEXT" | jq -r '.access_token // empty')

if [ -z "$CUSTOMER_TOKEN" ]; then
    echo -e "${RED}  Failed to switch to customer sub-org${NC}"
    exit 1
fi

echo -e "${GREEN}  Switched to: $CUSTOMER_ORG_ID${NC}"
echo ""

# ==============================================================================
# Step 4: Register approved permissions on customer sub-org
#
# INTENT: The provider decides EXACTLY which permissions the consumer gets.
#         By registering these on the sub-org, they become the ceiling.
#         The consumer cannot exceed this set.
#
#         This is the equivalent of registering permissions on the end-users
#         org in step 04 — the schema must exist on the org for permission
#         queries to work.
# ==============================================================================
echo -e "${BLUE}Step 4: Registering approved permissions on customer sub-org${NC}"

# Extract unique service prefix from permissions (e.g., "billing" from "billing.read")
PERM_SERVICE=$(echo "$PERMISSIONS_JSON" | jq -r '.[0]' | cut -d. -f1)

PERM_REG_RESPONSE=$(curl -s -w "\nHTTP_CODE:%{http_code}" \
    -X POST "$AUTH_SERVICE_URL/permissions/registry/register" \
    -H "Authorization: Bearer $CUSTOMER_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{
        "service": "'"$PERM_SERVICE"'",
        "description": "Approved permissions for '"$CLIENT_SERVICE_NAME"' consumer access",
        "actions": '"$(echo "$PERMISSIONS_JSON" | jq -c '[.[] | split(".") | .[1]] | unique')"',
        "resources": '"$(echo "$PERMISSIONS_JSON" | jq -c '[.[] | split(".") | select(length > 2) | .[2]] | unique')"'
    }' 2>&1)

HTTP_CODE=$(echo "$PERM_REG_RESPONSE" | grep "HTTP_CODE" | cut -d: -f2)

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
    echo -e "${GREEN}  Registered $PERMISSION_COUNT permissions on sub-org${NC}"
else
    echo -e "${YELLOW}  Permission registry returned HTTP $HTTP_CODE (non-fatal)${NC}"
fi

echo ""

# ==============================================================================
# Step 5: Create approved-permissions team
#
# INTENT: Same pattern as the "Default Users" team in step 04.
#         Service accounts that register on this sub-org auto-join this team
#         and inherit ONLY the permissions the provider put on it.
#
#         This is where the provider controls scope. The team's permissions
#         are the APPROVED set. The consumer inherits them through Zanzibar
#         team membership — same as end-users inherit through their team.
# ==============================================================================
echo -e "${BLUE}Step 5: Creating approved-permissions team${NC}"

CONSUMER_TEAM_ID=""

# Check if team already exists (idempotent)
EXISTING_TEAMS=$(curl -s "$AUTH_SERVICE_URL/organizations/$CUSTOMER_ORG_ID/teams" \
    -H "Authorization: Bearer $CUSTOMER_TOKEN" 2>/dev/null || echo "[]")

FOUND_TEAM=$(echo "$EXISTING_TEAMS" | jq -r \
    --arg name "$CONSUMER_TEAM_NAME" \
    '.[] | select(.name == $name) | .id' 2>/dev/null | head -n1)

if [ -n "$FOUND_TEAM" ] && [ "$FOUND_TEAM" != "null" ]; then
    CONSUMER_TEAM_ID="$FOUND_TEAM"
    echo -e "${GREEN}  Team already exists: $CONSUMER_TEAM_ID${NC}"
else
    TEAM_RESPONSE=$(curl -s -X POST "$AUTH_SERVICE_URL/organizations/$CUSTOMER_ORG_ID/teams" \
        -H "Authorization: Bearer $CUSTOMER_TOKEN" \
        -H "Content-Type: application/json" \
        -d '{
            "name": "'"$CONSUMER_TEAM_NAME"'",
            "description": "Provider-approved permissions for '"$CLIENT_SERVICE_NAME"'. Service accounts auto-join this team on registration.",
            "permissions": '"$PERMISSIONS_JSON"'
        }' 2>&1)

    CONSUMER_TEAM_ID=$(echo "$TEAM_RESPONSE" | jq -r '.id // .team_id // empty')

    if [ -z "$CONSUMER_TEAM_ID" ] || [ "$CONSUMER_TEAM_ID" = "null" ]; then
        echo -e "${RED}  Failed to create team${NC}"
        echo "  Response: $TEAM_RESPONSE"
        exit 1
    fi

    echo -e "${GREEN}  Created team: $CONSUMER_TEAM_ID${NC}"
fi

echo "  Permissions on team:"
echo "$PERMISSIONS_JSON" | jq -r '.[]' | while read -r p; do echo "    • $p"; done
echo ""

# ==============================================================================
# Step 6: Configure login on customer sub-org (auto-join team)
#
# INTENT: When a service account registers on this sub-org via the org-scoped
#         endpoint, it automatically joins the "Consumer Access" team and
#         inherits the approved permissions.
#
#         This is the EXACT same mechanism as 04-setup-default-team.sh:
#           login config → default_team → auto-join → Zanzibar → permissions
#
#         The consumer never needs to be invited or granted anything manually.
#         They just register and the permissions flow through the team.
# ==============================================================================
echo -e "${BLUE}Step 6: Configuring auto-join on customer sub-org${NC}"

LOGIN_CONFIG_RESPONSE=$(curl -s -w "\nHTTP_CODE:%{http_code}" \
    -X PUT "$AUTH_SERVICE_URL/organizations/$CUSTOMER_ORG_ID/login-config" \
    -H "Authorization: Bearer $CUSTOMER_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{
        "auth_methods": {
            "email_password": true,
            "signup_enabled": true,
            "invitation_only": false
        },
        "registration": {
            "default_role": "member",
            "default_team": "'"$CONSUMER_TEAM_ID"'",
            "collect_name": true
        },
        "branding": {
            "page_title": "'"$PROVIDER_SERVICE_NAME"' - Consumer Registration"
        }
    }' 2>&1)

HTTP_CODE=$(echo "$LOGIN_CONFIG_RESPONSE" | grep "HTTP_CODE" | cut -d: -f2)

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
    echo -e "${GREEN}  Login config applied${NC}"
    echo "  default_role: member"
    echo "  default_team: $CONSUMER_TEAM_ID"
    echo "  signup_enabled: true (consumers can self-register)"
else
    echo -e "${YELLOW}  Login config returned HTTP $HTTP_CODE${NC}"
fi

echo ""

# ==============================================================================
# Step 7: Save invitation file
#
# INTENT: This file is what the consumer needs to self-register. It contains
#         NO SECRETS — just the org slug and auth URL. The consumer uses it
#         with consumer-register.sh to create their service account.
#
#         In a multi-team deployment, this file would be sent to the consumer
#         team out-of-band (email, Slack, API, etc.).
# ==============================================================================
echo -e "${BLUE}Step 7: Saving invitation${NC}"

mkdir -p "$INVITATION_DIR"

CREATED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

cat > "$INVITATION_FILE" <<EOF
{
    "invitation": {
        "provider": {
            "service_id": "$PROVIDER_SERVICE_ID",
            "service_name": "$PROVIDER_SERVICE_NAME",
            "service_url": "$PROVIDER_SERVICE_URL"
        },
        "customer_org": {
            "id": "$CUSTOMER_ORG_ID",
            "slug": "$CUSTOMER_ORG_SLUG",
            "name": "$CUSTOMER_ORG_NAME"
        },
        "auth_service_url": "$AUTH_SERVICE_URL",
        "approved_permissions": $PERMISSIONS_JSON,
        "team_name": "$CONSUMER_TEAM_NAME",
        "registration_endpoint": "$AUTH_SERVICE_URL/organizations/$CUSTOMER_ORG_SLUG/auth/register"
    },
    "instructions": "Use consumer-register.sh with this file to self-register.",
    "created_at": "$CREATED_AT",
    "created_by": "provider-accept-consumer.sh"
}
EOF

echo -e "${GREEN}  Saved: $INVITATION_FILE${NC}"
echo ""

# ==============================================================================
# Summary
# ==============================================================================
echo -e "${CYAN}=== Provider Setup Complete ===${NC}"
echo ""
echo "  Auth Service"
echo "  └── ${PROVIDER_SERVICE_NAME} ($PROVIDER_ORG_ID)"
echo "      └── ${CUSTOMER_ORG_NAME} ($CUSTOMER_ORG_ID)"
echo "          └── ${CONSUMER_TEAM_NAME} team"
echo "              └── ${PERMISSION_COUNT} approved permissions"
echo ""
echo "  Approved permissions:"
echo "$PERMISSIONS_JSON" | jq -r '.[]' | while read -r p; do echo "    • $p"; done
echo ""
echo "  Invitation file: $INVITATION_FILE"
echo ""
echo -e "${YELLOW}Next step:${NC}"
echo "  Give the invitation file to the consumer team."
echo "  They run:"
echo ""
echo "    bash consumer-register.sh $INVITATION_FILE"
echo ""
echo "  The consumer self-registers, auto-joins the team, and gets"
echo "  ONLY the permissions you approved."
echo ""
