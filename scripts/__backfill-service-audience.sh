#!/usr/bin/env bash
# Ticket:20260309_service_audience_token_fix Task 7
# One-time backfill: set service_audience on existing dev orgs
#
# WHY: Tasks 1-4 added service_audience resolution to token generation.
#      Existing org records in DynamoDB have no service_audience attribute.
#      Without backfill, tokens fall back to LOCAL:{org_id} (old behavior).
#
# IDEMPOTENT: Safe to run multiple times. SET overwrites with same value.
#
# Usage:
#   DYNAMODB_ENDPOINT=http://localhost:8000 ./backfill-service-audience.sh           # local DynamoDB
#   ENVIRONMENT=production ./backfill-service-audience.sh                            # real AWS (no endpoint override)
#   ENVIRONMENT=production DYNAMODB_ENDPOINT=http://... ./backfill-service-audience.sh  # custom endpoint

set -u
set -o pipefail

TABLE_NAME="${DYNAMODB_TABLE:-auth_service_data}"
ENDPOINT="${DYNAMODB_ENDPOINT:-}"
SERVICE_AUDIENCE="integration-service"

# Org IDs per environment (from setup credentials)
# Ticket:20260309 Task D — extended for all environments
ENV="${ENVIRONMENT:-dev}"

case "$ENV" in
  dev)
    ROOT_ORG_ID="83f9767f-d82f-4bf2-9a6c-8698068159a8"
    CHILD_ORG_ID="f27cf687-4177-4f7d-92d8-ff7163bbc1d3"
    ;;
  production)
    ROOT_ORG_ID="09a39e0c-bc43-4a07-a450-0ff866e65a2a"
    CHILD_ORG_ID="d5be0003-a7ee-4da3-aa86-1e6649479e94"
    ;;
  staging)
    echo "ERROR: Staging org IDs not yet provisioned. Set ROOT_ORG_ID and CHILD_ORG_ID manually."
    exit 1
    ;;
  *)
    echo "ERROR: Unknown ENVIRONMENT=$ENV. Use dev, staging, or production."
    exit 1
    ;;
esac

ENDPOINT_ARG=""
if [ -n "$ENDPOINT" ]; then
  ENDPOINT_ARG="--endpoint-url $ENDPOINT"
fi

PASS=0
FAIL=0

backfill_org() {
  local org_id="$1"
  local label="$2"

  echo "Backfilling $label ($org_id) → service_audience=$SERVICE_AUDIENCE"

  # shellcheck disable=SC2086
  aws dynamodb update-item \
    --table-name "$TABLE_NAME" \
    --key '{"PK": {"S": "ORG#'"$org_id"'"}, "SK": {"S": "METADATA"}}' \
    --update-expression "SET service_audience = :sa" \
    --expression-attribute-values '{":sa": {"S": "'"$SERVICE_AUDIENCE"'"}}' \
    $ENDPOINT_ARG 2>&1

  if [ $? -eq 0 ]; then
    echo "  ✓ $label backfilled"
    PASS=$((PASS + 1))
  else
    echo "  ✗ $label FAILED"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== Service Audience Backfill ==="
echo "Environment: $ENV"
echo "Table: $TABLE_NAME"
echo "Endpoint: ${ENDPOINT:-AWS (default region)}"
echo "Target audience: $SERVICE_AUDIENCE"
echo ""

backfill_org "$ROOT_ORG_ID" "root org (integration)"
backfill_org "$CHILD_ORG_ID" "child org (integration-users)"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

# Verify
echo ""
echo "=== Verification ==="
for ORG_ID in "$ROOT_ORG_ID" "$CHILD_ORG_ID"; do
  # shellcheck disable=SC2086
  RESULT="$(aws dynamodb get-item \
    --table-name "$TABLE_NAME" \
    --key '{"PK": {"S": "ORG#'"$ORG_ID"'"}, "SK": {"S": "METADATA"}}' \
    --projection-expression "id, slug, service_audience" \
    $ENDPOINT_ARG 2>&1)"

  SA="$(echo "$RESULT" | jq -r '.Item.service_audience.S // "NOT SET"')"
  SLUG="$(echo "$RESULT" | jq -r '.Item.slug.S // "?"')"
  echo "  $SLUG ($ORG_ID): service_audience=$SA"
done

exit $FAIL
