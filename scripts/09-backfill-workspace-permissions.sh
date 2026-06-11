#!/bin/bash
# ==============================================================================
# 09-backfill-workspace-permissions.sh — Sync default_grant perms to EXISTING
#                                        per-user workspace teams
#
# INTENT:
#   You added a new `default_grant: true` permission (or changed the set) AFTER
#   users had already registered under org_structure.pattern=workspace-per-user.
#   New signups get the perm (the workspace template was refreshed by script 04);
#   EXISTING workspaces still carry the team-permissions snapshot from when they
#   were created, so those users 403. This script reconciles every existing
#   workspace's default team to the UNION of (existing ∪ canonical default_grant
#   set ∪ EXTRA_PERMS). Additive only — never removes a perm.
#
#   Companion to SYNC_EXISTING=1 in script 04:
#     04 SYNC_EXISTING  → the SHARED end-users team   (flat / self-service case)
#     this script       → each user's PRIVATE workspace team (workspace-per-user)
#
#   Ticket: auth/tickets/20260609_llm_gateway_permission_propagation (TICKET.md §5/§6)
#
# HOW IT FINDS WORKSPACES:
#   Children of the end-users org that contain a team named after
#   org_structure.config.default_team_name (default "Default"). We match by
#   team presence rather than settings.type because /hierarchy hides org
#   `settings` since auth ticket 20260402 Task 41. Non-workspace child orgs
#   that happen to have a same-named team only ever receive the additive
#   default_grant union — harmless by construction.
#
# IDEMPOTENT: re-run safe; unchanged workspaces are no-ops.
# ADDITIVE:   computes union; never deletes custom perms.
#
# Usage:
#   DRY_RUN=1 ./scripts/09-backfill-workspace-permissions.sh   # ALWAYS run this first
#   ./scripts/09-backfill-workspace-permissions.sh
#   ONLY_ORG_ID=<workspace_org_id> ./scripts/09-backfill-workspace-permissions.sh
#                                       # single-workspace validation (e.g. mike+prod5)
#   EXTRA_PERMS_JSON='["gateway.write.provider_keys","gateway.delete.provider_keys"]' \
#     ./scripts/09-backfill-workspace-permissions.sh
#                                       # add role-tier perms beyond default_grant
#                                       # (custom roles don't resolve server-side yet —
#                                       #  see CUSTOM_ROLES_FEASIBILITY.md)
#   RATE_DELAY=0.2 ...                  # seconds between workspaces (default 0.1)
#
# NOTE: after a successful sync, users may take up to ~5 minutes to see the new
# permission (auth permission cache TTL). A fresh login/token applies immediately.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_DIR="${SETUP_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
AUTH_SERVICE_URL="${AUTH_SERVICE_URL:-https://auth.service.ab0t.com}"
DRY_RUN="${DRY_RUN:-0}"
ONLY_ORG_ID="${ONLY_ORG_ID:-}"
EXTRA_PERMS_JSON="${EXTRA_PERMS_JSON:-[]}"
RATE_DELAY="${RATE_DELAY:-0.1}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

for cmd in jq python3 curl; do
  command -v "$cmd" >/dev/null 2>&1 || { echo -e "${RED}ERROR: $cmd is required${NC}"; exit 1; }
done

# ─── Load config + credentials (mirrors script 04's resolution) ──────────────
PERMISSIONS_FILE="${PERMISSIONS_FILE:-$SETUP_DIR/config/permissions.json}"
[ -f "$PERMISSIONS_FILE" ] || { echo -e "${RED}ERROR: $PERMISSIONS_FILE not found${NC}"; exit 1; }

if echo "$AUTH_SERVICE_URL" | grep -qE "localhost|dev\.ab0t\.com"; then ENV_SUFFIX="-dev"; else ENV_SUFFIX=""; fi

SERVICE_ID="$(jq -r '.service.id' "$PERMISSIONS_FILE")"
CREDS_FILE="$SETUP_DIR/credentials/${SERVICE_ID}${ENV_SUFFIX}.json"
[ ! -f "$CREDS_FILE" ] && [ -n "$ENV_SUFFIX" ] && [ -f "$SETUP_DIR/credentials/${SERVICE_ID}.json" ] \
  && CREDS_FILE="$SETUP_DIR/credentials/${SERVICE_ID}.json"
[ -f "$CREDS_FILE" ] || { echo -e "${RED}ERROR: no service credentials — run 01 first${NC}"; exit 1; }

EU_FILE="$SETUP_DIR/credentials/end-users-org${ENV_SUFFIX}.json"
[ ! -f "$EU_FILE" ] && [ -f "$SETUP_DIR/credentials/end-users-org.json" ] \
  && EU_FILE="$SETUP_DIR/credentials/end-users-org.json"
[ -f "$EU_FILE" ] || { echo -e "${RED}ERROR: no end-users-org credentials — run 04 first${NC}"; exit 1; }

END_USERS_ORG_ID="$(jq -r '.org_id' "$EU_FILE")"
ORG_PATTERN="$(jq -r '.org_structure.pattern // "flat"' "$EU_FILE")"
WS_TEAM_NAME="$(jq -r '.org_structure.config.default_team_name // "Default"' "$EU_FILE")"
DEFAULT_PERMS_JSON="$(jq -c '[.permissions[] | select(.default_grant == true) | .id]' "$PERMISSIONS_FILE")"
TARGET_BASE="$(jq -cn --argjson d "$DEFAULT_PERMS_JSON" --argjson e "$EXTRA_PERMS_JSON" '$d + $e | unique')"

echo -e "${CYAN}=== Workspace Permission Backfill ===${NC}"
echo ""
echo "End-Users Org:   $END_USERS_ORG_ID"
echo "Pattern:         $ORG_PATTERN"
echo "Workspace team:  $WS_TEAM_NAME"
echo "Canonical set:   $(echo "$TARGET_BASE" | jq -r 'length') perms → $(echo "$TARGET_BASE" | jq -cr '.')"
echo "Auth Service:    $AUTH_SERVICE_URL"
[ -n "$ONLY_ORG_ID" ] && echo -e "${YELLOW}Single target:   $ONLY_ORG_ID${NC}"
[ "$DRY_RUN" = "1" ] && echo -e "${YELLOW}DRY RUN — no writes${NC}"
echo ""

if [ "$ORG_PATTERN" != "workspace-per-user" ]; then
  echo -e "${YELLOW}org_structure.pattern is '$ORG_PATTERN' (not workspace-per-user).${NC}"
  echo -e "${YELLOW}For the shared end-users team use: SYNC_EXISTING=1 ./scripts/04-setup-default-team.sh${NC}"
  exit 0
fi

# ─── Step 1: admin token (end-users org context) ─────────────────────────────
echo -e "${BLUE}Step 1: Logging in as service admin (end-users org context)${NC}"
ACCESS_TOKEN="$(python3 - "$CREDS_FILE" "$END_USERS_ORG_ID" "$AUTH_SERVICE_URL" << 'PYEOF'
import json, sys, urllib.request, ssl
creds = json.load(open(sys.argv[1]))
data = json.dumps({"email": creds["admin"]["email"], "password": creds["admin"]["password"],
                   "org_id": sys.argv[2]}).encode()
req = urllib.request.Request(sys.argv[3] + "/auth/login", data=data,
                             headers={"Content-Type": "application/json"})
try:
    print(json.loads(urllib.request.urlopen(req, context=ssl.create_default_context()).read())["access_token"])
except Exception as e:
    sys.exit(f"LOGIN FAILED: {e}")
PYEOF
)"
[ -n "$ACCESS_TOKEN" ] || { echo -e "${RED}Login failed${NC}"; exit 1; }
echo -e "${GREEN}Logged in${NC}"

# ─── Step 2: enumerate candidate workspace orgs ──────────────────────────────
echo -e "${BLUE}Step 2: Enumerating child orgs of end-users org${NC}"
if [ -n "$ONLY_ORG_ID" ]; then
  CHILD_IDS="$ONLY_ORG_ID"
else
  HIERARCHY="$(curl -s --retry 3 --retry-delay 2 \
    "$AUTH_SERVICE_URL/organizations/$END_USERS_ORG_ID/hierarchy" \
    -H "Authorization: Bearer $ACCESS_TOKEN")"
  # All descendant orgs (recursive) — workspaces sit one level under the
  # end-users org, but deeper sub-orgs are included too; non-workspaces are
  # filtered out below by the team-name check (or receive a harmless no-op).
  CHILD_IDS="$(echo "$HIERARCHY" | jq -r '.. | objects | select(has("children")) | .children[]?.id // empty' \
    | sort -u)"
fi
CHILD_COUNT="$(echo "$CHILD_IDS" | grep -c . || true)"
echo -e "${GREEN}Found $CHILD_COUNT candidate child org(s)${NC}"
[ "$CHILD_COUNT" -gt 0 ] || { echo "Nothing to do."; exit 0; }

# ─── Step 3: reconcile each workspace's default team ─────────────────────────
echo -e "${BLUE}Step 3: Reconciling workspace teams${NC}"
SYNCED=0; NOOP=0; SKIPPED=0; FAILED=0
FAILED_IDS=""

for WS_ID in $CHILD_IDS; do
  TEAMS="$(curl -s --retry 3 --retry-delay 2 \
    "$AUTH_SERVICE_URL/organizations/$WS_ID/teams" \
    -H "Authorization: Bearer $ACCESS_TOKEN" 2>/dev/null || echo "[]")"
  echo "$TEAMS" | jq -e 'type=="array"' >/dev/null 2>&1 || TEAMS="[]"

  TEAM_ROW="$(echo "$TEAMS" | jq -c --arg n "$WS_TEAM_NAME" '[.[] | select(.name==$n)] | first // empty')"
  if [ -z "$TEAM_ROW" ]; then
    SKIPPED=$((SKIPPED+1))
    echo -e "  ${YELLOW}skip${NC}  $WS_ID — no team named '$WS_TEAM_NAME' (not a workspace?)"
    continue
  fi

  TEAM_ID="$(echo "$TEAM_ROW" | jq -r '.id')"
  CUR="$(echo "$TEAM_ROW" | jq -c '.permissions // []')"
  CUR="${CUR:-[]}"
  TGT="$(jq -cn --argjson cur "$CUR" --argjson base "$TARGET_BASE" '$cur + $base | unique')"
  MISSING="$(jq -cn --argjson cur "$CUR" --argjson tgt "$TGT" '$tgt - $cur')"
  N_MISSING="$(echo "$MISSING" | jq 'length')"

  if [ "$N_MISSING" -eq 0 ]; then
    NOOP=$((NOOP+1))
    continue
  fi

  if [ "$DRY_RUN" = "1" ]; then
    SYNCED=$((SYNCED+1))
    echo -e "  ${CYAN}would sync${NC} $WS_ID team=$TEAM_ID +$N_MISSING: $(echo "$MISSING" | jq -cr '.')"
    continue
  fi

  CODE="$(curl -s --retry 3 --retry-delay 2 -o /tmp/bf_resp_$$.json -w "%{http_code}" \
    -X PUT "$AUTH_SERVICE_URL/teams/$TEAM_ID" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"permissions\": $TGT}")"
  if [ "$CODE" = "200" ] || [ "$CODE" = "201" ]; then
    SYNCED=$((SYNCED+1))
    echo -e "  ${GREEN}synced${NC} $WS_ID team=$TEAM_ID +$N_MISSING: $(echo "$MISSING" | jq -cr '.')"
  else
    FAILED=$((FAILED+1)); FAILED_IDS="$FAILED_IDS $WS_ID"
    echo -e "  ${RED}FAIL${NC}  $WS_ID team=$TEAM_ID HTTP $CODE: $(jq -cr '.detail // .' /tmp/bf_resp_$$.json 2>/dev/null | head -c 200)"
  fi
  sleep "$RATE_DELAY"
done
rm -f /tmp/bf_resp_$$.json

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}=== Backfill Summary ===${NC}"
echo "Candidates: $CHILD_COUNT | Synced: $SYNCED | Already-current: $NOOP | Skipped(no team): $SKIPPED | Failed: $FAILED"
[ -n "$FAILED_IDS" ] && echo -e "${RED}Failed org ids:$FAILED_IDS${NC}"

echo ""
echo "NEXT —"
if [ "$DRY_RUN" = "1" ]; then
  echo "  This was a DRY RUN. Review the 'would sync' lines above, then either:"
  echo "    1. Validate ONE workspace first (recommended):"
  echo "       ONLY_ORG_ID=<that_org_id> $0"
  echo "       → then have that user re-login and retry the previously-403 endpoint."
  echo "    2. Run the full sweep: $0"
  echo "  WHY: prove the PUT→Zanzibar-resync lever end-to-end on one user before touching all."
elif [ "$FAILED" -gt 0 ]; then
  echo "  $FAILED workspace(s) failed — re-run this script (idempotent; only failures will re-sync)."
  echo "  If failures persist, check the admin token's org.admin/teams.write on those child orgs."
elif [ "$SYNCED" -gt 0 ]; then
  echo "  Synced $SYNCED workspace(s). Affected users see new perms within ~5 min (perm cache TTL),"
  echo "  or immediately after a fresh login. Verify one:"
  echo "    ./scripts/curl_tests/auth_cli.sh perm user-perms <user_id>   (from auth repo), or"
  echo "    have the reporting user retry the previously-403 endpoint."
  echo "  WHY: confirms the cache rolled and the Zanzibar resync took effect."
else
  echo "  Everything already current — no writes needed. Safe to re-run any time the"
  echo "  default_grant set changes (pair with SYNC_EXISTING=1 ./scripts/04-... for the shared team)."
fi
