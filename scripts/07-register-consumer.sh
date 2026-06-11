#!/bin/bash
# ==============================================================================
# 07-register-consumer.sh — Register this service as a CONSUMER of other mesh services
#
# INTENT:
#   YOU WANT TO CALL OTHER SERVICES' APIs.
#
#   This is the CONSUMER side of the mesh. Run this when your service needs
#   to make authenticated API calls to upstream providers (e.g., billing,
#   payment). It creates a service account and API key on each provider so
#   your backend can call their endpoints with X-API-Key.
#
#   This is the opposite of step 08. Step 08 opens YOUR service so others
#   can consume it. Step 07 registers YOU as a consumer of THEIR services.
#
#   Direction: YOUR SERVICE → calls → PROVIDER SERVICES
#
# WHO RUNS THIS:
#   Any service that needs to consume upstream mesh services.
#   Run after step 01 (your service must be registered first).
#   Providers must have registered their services and run step 08 (or
#   provider-accept-consumer.sh) to accept consumers.
#
# HOW IT WORKS:
#   For each provider in clients.d/*.json:
#     1. Calls register-as-client.sh (the registration engine)
#     2. Engine creates a customer sub-org under the provider
#     3. Creates a service account and scoped API key
#     4. Saves output to credentials/<provider>-consumer.json
#
#   Auth Service
#   ├── Billing Org (provider)
#   │   └── Your Service - Billing Customer (sub-org)
#   │       └── your-service@billing.customers (service account)
#   │           └── API key: billing.read.*, billing.cross_tenant
#   │
#   └── Your Service Org (this service)
#       └── Stores consumer API keys in .env
#
# PREREQUISITES:
#   - Auth service running and healthy
#   - Step 01 completed (your service registered)
#   - Provider services registered (providers must have run their own
#     register-service-permissions.sh)
#
# USAGE:
#   ./07-register-consumer.sh                  # Register with ALL providers
#   ./07-register-consumer.sh billing          # Register with billing only
#   ./07-register-consumer.sh payment          # Register with payment only
#   ./07-register-consumer.sh billing payment  # Register with specific providers
#
# OUTPUTS:
#   credentials/billing-consumer.json    — Billing customer org + API key
#   credentials/payment-consumer.json    — Payment customer org + API key
#
# IDEMPOTENT: Safe to run multiple times. Old API keys remain valid.
#
# SEE ALSO:
#   - service-client-setup/register-as-client.sh  (reusable registration engine)
#   - service-client-setup/consumer-register.sh   (self-service registration engine)
#   - service-client-setup/clients.d/*.json        (provider configs)
#   - service-client-setup/README.md               (detailed docs)
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CLIENT_SETUP_DIR="$SCRIPT_DIR/service-client-setup"
CREDS_DIR="$SETUP_DIR/credentials"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

AUTH_SERVICE_URL="${AUTH_SERVICE_URL:-https://auth.service.ab0t.com}"

# ==============================================================================
# Determine which providers to register with
# ==============================================================================

if [ $# -gt 0 ]; then
    PROVIDERS=("$@")
else
    # Default: all providers with config files
    PROVIDERS=()
    for config_file in "$CLIENT_SETUP_DIR/clients.d"/*.json; do
        if [ -f "$config_file" ]; then
            provider=$(basename "$config_file" .json)
            PROVIDERS+=("$provider")
        fi
    done
fi

if [ ${#PROVIDERS[@]} -eq 0 ]; then
    echo -e "${YELLOW}No provider configs found in $CLIENT_SETUP_DIR/clients.d/${NC}"
    echo "Skipping — this service doesn't consume any upstream providers."
    echo "To add one: cp clients.d/example.json.example clients.d/<provider>.json"
    exit 0
fi

echo ""
echo -e "${MAGENTA}=== Sandbox Platform — Consumer Registration ===${NC}"
echo ""
echo "  Auth Service: $AUTH_SERVICE_URL"
echo "  Providers:    ${PROVIDERS[*]}"
echo ""

# ==============================================================================
# Preflight checks
# ==============================================================================

echo -e "${BLUE}Preflight${NC}"

# Check auth service health
if ! curl -sf "$AUTH_SERVICE_URL/health" >/dev/null 2>&1; then
    echo -e "${RED}  Auth service not reachable at $AUTH_SERVICE_URL${NC}"
    exit 1
fi
echo -e "${GREEN}  Auth service healthy${NC}"

# Check register-as-client.sh exists
if [ ! -x "$CLIENT_SETUP_DIR/register-as-client.sh" ]; then
    echo -e "${RED}  register-as-client.sh not found or not executable${NC}"
    exit 1
fi
echo -e "${GREEN}  register-as-client.sh found${NC}"

# Check jq
if ! command -v jq &>/dev/null; then
    echo -e "${RED}  jq is required but not installed${NC}"
    exit 1
fi
echo -e "${GREEN}  jq available${NC}"

echo ""

# ==============================================================================
# Register with each provider
# ==============================================================================

PASS_COUNT=0
FAIL_COUNT=0
RESULTS=()

for PROVIDER in "${PROVIDERS[@]}"; do
    CONFIG_FILE="$CLIENT_SETUP_DIR/clients.d/${PROVIDER}.json"

    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}Config not found: $CONFIG_FILE${NC}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        RESULTS+=("FAIL: $PROVIDER (config not found)")
        continue
    fi

    echo -e "${CYAN}--- Registering with: $PROVIDER ---${NC}"
    echo ""

    # Run the reusable registration script
    if AUTH_SERVICE_URL="$AUTH_SERVICE_URL" \
       bash "$CLIENT_SETUP_DIR/register-as-client.sh" "$PROVIDER"; then

        # Copy output to main credentials directory with -consumer suffix
        CLIENT_CREDS="$CLIENT_SETUP_DIR/credentials/${PROVIDER}-client.json"
        CONSUMER_CREDS="$CREDS_DIR/${PROVIDER}-consumer.json"

        if [ -f "$CLIENT_CREDS" ]; then
            cp "$CLIENT_CREDS" "$CONSUMER_CREDS"
            echo -e "${GREEN}  Copied to: $CONSUMER_CREDS${NC}"

            # Extract the API key for display
            API_KEY=$(jq -r '.api_key.key' "$CONSUMER_CREDS")
            echo ""
            echo -e "${YELLOW}  Set in sandbox-platform .env:${NC}"

            PROVIDER_UPPER=$(echo "$PROVIDER" | tr '[:lower:]' '[:upper:]')
            echo "    ${PROVIDER_UPPER}_SERVICE_API_KEY=${API_KEY}"
        fi

        PASS_COUNT=$((PASS_COUNT + 1))
        RESULTS+=("PASS: $PROVIDER")
    else
        echo -e "${RED}  Failed to register with $PROVIDER${NC}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        RESULTS+=("FAIL: $PROVIDER")
    fi

    echo ""
done

# ==============================================================================
# Summary
# ==============================================================================

echo ""
echo -e "${MAGENTA}=== Consumer Registration Summary ===${NC}"
echo ""
for result in "${RESULTS[@]}"; do
    if [[ "$result" == PASS* ]]; then
        echo -e "  ${GREEN}$result${NC}"
    else
        echo -e "  ${RED}$result${NC}"
    fi
done
echo ""
echo -e "  ${GREEN}PASS: $PASS_COUNT${NC}  ${RED}FAIL: $FAIL_COUNT${NC}"
echo ""

if [ $PASS_COUNT -gt 0 ]; then
    echo -e "${YELLOW}Next steps:${NC}"
    echo "  1. Update sandbox-platform .env with the API keys shown above"
    echo "  2. Rebuild: docker compose up -d --build"
    echo "  3. Verify: run UJ-002 (billing) and UJ-003 (payment)"
fi

if [ $FAIL_COUNT -gt 0 ]; then
    echo ""
    echo -e "${RED}Some registrations failed. Check:${NC}"
    echo "  - Provider service registered? (run provider's register-service-permissions.sh)"
    echo "  - Provider credentials exist? (check path in clients.d/<provider>.json)"
    echo "  - Auth service healthy? ($AUTH_SERVICE_URL/health)"
    exit 1
fi
