#!/usr/bin/env bash
# Validate setup config and credential files using jq.
#
# Checks:
#   - Required fields exist and are non-empty
#   - Permission IDs match {service}.{action}.{resource} format
#   - Role permissions reference defined permission IDs
#   - Credential files have expected structure (after setup)
#   - Cross-file consistency (e.g., service.id matches across files)
#
# Zero dependencies beyond jq (already required by all setup scripts).
#
# Usage:
#   ./scripts/validate-config.sh                    # validate config/ files
#   ./scripts/validate-config.sh --credentials      # also validate credentials/
#   ./scripts/validate-config.sh --file config/permissions.json  # single file
#   ./scripts/validate-config.sh --quiet            # exit code only

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_DIR="${SETUP_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
VALIDATE_CREDENTIALS=false
SINGLE_FILE=""
QUIET=false

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --credentials|-c) VALIDATE_CREDENTIALS=true; shift ;;
    --file|-f)        SINGLE_FILE="$2"; shift 2 ;;
    --quiet|-q)       QUIET=true; shift ;;
    --help|-h)
      echo "Usage: validate-config.sh [--credentials] [--file <path>] [--quiet]"
      exit 0
      ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# Colors (disabled in quiet mode)
if [ "$QUIET" = true ]; then
  RED=''; GREEN=''; YELLOW=''; CYAN=''; NC=''
else
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  CYAN='\033[0;36m'; NC='\033[0m'
fi

PASS=0
FAIL=0
WARN=0

pass() { ((PASS++)); [ "$QUIET" = true ] || echo -e "  ${GREEN}✓${NC} $1"; }
fail() { ((FAIL++)); echo -e "  ${RED}✗${NC} $1" >&2; }
warn() { ((WARN++)); [ "$QUIET" = true ] || echo -e "  ${YELLOW}!${NC} $1"; }
section() { [ "$QUIET" = true ] || echo -e "\n${CYAN}=== $1 ===${NC}"; }

# ──────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────

# Check that a jq path exists and is non-empty in a file
# Usage: require_field <file> <jq_path> <label>
require_field() {
  local file="$1" path="$2" label="$3"
  local val
  val="$(jq -r "$path // empty" "$file" 2>/dev/null)"
  if [ -z "$val" ]; then
    fail "$label: missing ($path in $(basename "$file"))"
    return 1
  fi
  pass "$label"
  return 0
}

# Check that a jq path returns a non-empty array
# Usage: require_array <file> <jq_path> <label> [min_length]
require_array() {
  local file="$1" path="$2" label="$3" min="${4:-1}"
  local len
  len="$(jq "$path | length" "$file" 2>/dev/null)"
  if [ -z "$len" ] || [ "$len" -lt "$min" ]; then
    fail "$label: expected array with >= $min items, got ${len:-null} ($path)"
    return 1
  fi
  pass "$label ($len items)"
  return 0
}

# Check a field matches a regex
# Usage: require_match <file> <jq_path> <regex> <label>
require_match() {
  local file="$1" path="$2" regex="$3" label="$4"
  local val
  val="$(jq -r "$path // empty" "$file" 2>/dev/null)"
  if [ -z "$val" ]; then
    fail "$label: missing ($path)"
    return 1
  fi
  if ! echo "$val" | grep -qE "$regex"; then
    fail "$label: '$val' does not match $regex"
    return 1
  fi
  pass "$label = $val"
  return 0
}

# ──────────────────────────────────────────────────────────────
# Validators
# ──────────────────────────────────────────────────────────────

validate_permissions() {
  local file="$1"
  section "permissions.json"

  if [ ! -f "$file" ]; then
    fail "File not found: $file"
    return
  fi

  # Valid JSON?
  if ! jq empty "$file" 2>/dev/null; then
    fail "Invalid JSON: $file"
    return
  fi
  pass "Valid JSON"

  # Required top-level sections
  require_field "$file" '.service.id'          "service.id"
  require_field "$file" '.service.name'        "service.name"
  require_field "$file" '.service.description' "service.description"
  require_field "$file" '.service.audience'    "service.audience"

  # Registration
  require_field "$file" '.registration.service'  "registration.service"
  require_array "$file" '.registration.actions'  "registration.actions"
  require_array "$file" '.registration.resources' "registration.resources"

  # Permissions array
  require_array "$file" '.permissions' "permissions" 1

  # Every permission must have: id, name, description, default_grant (bool)
  local perm_count
  perm_count="$(jq '.permissions | length' "$file")"
  local bad_perms
  bad_perms="$(jq -r '.permissions[] | select(.id == null or .name == null or .description == null or .default_grant == null) | .id // "UNNAMED"' "$file")"
  if [ -n "$bad_perms" ]; then
    fail "Permissions missing required fields (id, name, description, default_grant): $bad_perms"
  else
    pass "All $perm_count permissions have required fields"
  fi

  # Permission ID format: {service}.{action}.{resource} or {service}.{action}
  local service_id
  service_id="$(jq -r '.service.id' "$file")"
  local bad_ids
  bad_ids="$(jq -r --arg svc "$service_id" '.permissions[].id | select(startswith($svc + ".") | not)' "$file")"
  if [ -n "$bad_ids" ]; then
    fail "Permission IDs not prefixed with '$service_id.': $(echo "$bad_ids" | tr '\n' ', ')"
  else
    pass "All permission IDs prefixed with '$service_id.'"
  fi

  # Roles
  require_array "$file" '.roles' "roles" 1

  # Every role must have: id, name, permissions[]
  local bad_roles
  bad_roles="$(jq -r '.roles[] | select(.id == null or .name == null or .permissions == null) | .id // "UNNAMED"' "$file")"
  if [ -n "$bad_roles" ]; then
    fail "Roles missing required fields (id, name, permissions): $bad_roles"
  else
    pass "All roles have required fields"
  fi

  # Exactly one role should be default
  local default_count
  default_count="$(jq '[.roles[] | select(.default == true)] | length' "$file")"
  if [ "$default_count" -eq 0 ]; then
    warn "No default role (roles[].default == true) — will fall back to 'member'"
  elif [ "$default_count" -gt 1 ]; then
    fail "Multiple default roles ($default_count) — exactly one expected"
  else
    local default_role
    default_role="$(jq -r '.roles[] | select(.default == true) | .id' "$file")"
    pass "Default role: $default_role"
  fi

  # Role permissions must reference defined permission IDs
  local all_perm_ids
  all_perm_ids="$(jq -r '.permissions[].id' "$file" | sort)"
  local orphan_perms
  orphan_perms="$(jq -r '.roles[].permissions[]' "$file" | sort -u | while read -r p; do
    # Skip implied permissions (like integration.admin) — they're valid if defined
    if ! echo "$all_perm_ids" | grep -qxF "$p"; then
      echo "$p"
    fi
  done)"
  if [ -n "$orphan_perms" ]; then
    fail "Role references undefined permissions: $(echo "$orphan_perms" | tr '\n' ', ')"
  else
    pass "All role permissions reference defined IDs"
  fi

  # implies[] must reference defined permission IDs
  local bad_implies
  bad_implies="$(jq -r '.permissions[] | select(.implies != null) | .implies[]' "$file" | sort -u | while read -r p; do
    if ! echo "$all_perm_ids" | grep -qxF "$p"; then
      echo "$p"
    fi
  done)"
  if [ -n "$bad_implies" ]; then
    fail "implies[] references undefined permissions: $(echo "$bad_implies" | tr '\n' ', ')"
  else
    pass "All implies[] reference defined IDs"
  fi

  # registration.service should match service.id
  local reg_svc
  reg_svc="$(jq -r '.registration.service // empty' "$file")"
  if [ -n "$reg_svc" ] && [ "$reg_svc" != "$service_id" ]; then
    warn "registration.service ($reg_svc) differs from service.id ($service_id)"
  fi

  # At least one permission with default_grant: true
  local default_grant_count
  default_grant_count="$(jq '[.permissions[] | select(.default_grant == true)] | length' "$file")"
  if [ "$default_grant_count" -eq 0 ]; then
    warn "No permissions with default_grant: true — new users will have zero permissions"
  else
    pass "$default_grant_count permissions with default_grant: true"
  fi
}

validate_hosted_login() {
  local file="$1"
  section "hosted-login.json"

  if [ ! -f "$file" ]; then
    fail "File not found: $file"
    return
  fi

  if ! jq empty "$file" 2>/dev/null; then
    fail "Invalid JSON: $file"
    return
  fi
  pass "Valid JSON"

  require_field "$file" '.auth_methods.email_password' "auth_methods.email_password"
  require_field "$file" '.registration.default_role'   "registration.default_role"

  # Validate default_role is a known value
  local role
  role="$(jq -r '.registration.default_role' "$file")"
  case "$role" in
    end_user|member|admin|viewer|developer) pass "default_role '$role' is a known role" ;;
    *) warn "default_role '$role' is custom — make sure it exists in the auth service" ;;
  esac

  # Check signup/invite consistency
  local signup invite
  signup="$(jq -r '.auth_methods.signup_enabled // false' "$file")"
  invite="$(jq -r '.auth_methods.invitation_only // false' "$file")"
  if [ "$signup" = "false" ] && [ "$invite" = "false" ]; then
    warn "Both signup_enabled and invitation_only are false — no one can join"
  fi
  if [ "$signup" = "true" ] && [ "$invite" = "true" ]; then
    warn "signup_enabled and invitation_only are both true — invitation_only overrides signup"
  fi

  # Accept-invite redirect (PART3) consistency.
  # Each URL must have its origin present in the allowlist, otherwise
  # the auth service rejects the PUT with HTTP 400.
  local allowlist_count
  allowlist_count="$(jq -r '(.security.accept_invite_allowed_origins // []) | length' "$file")"
  for field in accept_invite_url accept_invite_error_url; do
    local url url_origin in_list
    url="$(jq -r ".security.${field} // \"\"" "$file")"
    if [ -z "$url" ] || [ "$url" = "null" ]; then
      continue
    fi
    url_origin="$(printf '%s' "$url" | sed -nE 's|^([^/]+//[^/]+).*$|\1|p')"
    if [ -z "$url_origin" ]; then
      warn "security.${field} is not a valid URL"
      continue
    fi
    if [ "$allowlist_count" = "0" ]; then
      warn "security.${field} is set but security.accept_invite_allowed_origins is empty (03-setup-hosted-login.sh will smart-default it from oauth-client.json redirect_uris if available)"
      continue
    fi
    in_list="$(jq -r --arg o "$url_origin" \
      '(.security.accept_invite_allowed_origins // []) | map(ascii_downcase) | index($o | ascii_downcase) // "no"' \
      "$file")"
    if [ "$in_list" = "no" ]; then
      warn "security.${field} origin '$url_origin' is not in security.accept_invite_allowed_origins (auth service will reject the PUT with HTTP 400)"
    else
      pass "security.${field} origin '$url_origin' is allowlisted"
    fi
  done

  # Allowlist entries must be clean origins (scheme + host, no path).
  local i=0
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    if ! printf '%s' "$entry" | grep -qE '^https?://[^/]+/?$'; then
      warn "security.accept_invite_allowed_origins[$i] '$entry' is not a clean origin — should be 'https://host[:port]' with no path"
    fi
    i=$((i + 1))
  done < <(jq -r '(.security.accept_invite_allowed_origins // [])[]?' "$file" 2>/dev/null)
}

validate_oauth_client() {
  local file="$1"
  section "oauth-client.json"

  if [ ! -f "$file" ]; then
    fail "File not found: $file"
    return
  fi

  if ! jq empty "$file" 2>/dev/null; then
    fail "Invalid JSON: $file"
    return
  fi
  pass "Valid JSON"

  require_field "$file" '.client_name'     "client_name"
  require_array "$file" '.redirect_uris'   "redirect_uris"
  require_array "$file" '.grant_types'     "grant_types"

  # redirect_uris should be valid URLs
  local bad_uris
  bad_uris="$(jq -r '.redirect_uris[]' "$file" | grep -vE '^https?://' || true)"
  if [ -n "$bad_uris" ]; then
    fail "redirect_uris contain non-HTTP URLs: $bad_uris"
  else
    pass "All redirect_uris are HTTP(S)"
  fi

  # Warn about localhost in redirect_uris (fine for dev, not for production)
  local localhost_uris
  localhost_uris="$(jq -r '.redirect_uris[]' "$file" | grep -c 'localhost' || true)"
  if [ "$localhost_uris" -gt 0 ]; then
    warn "$localhost_uris redirect_uri(s) use localhost — remove for production"
  fi

  # Public client should have token_endpoint_auth_method: none
  local auth_method
  auth_method="$(jq -r '.token_endpoint_auth_method // empty' "$file")"
  if [ "$auth_method" = "none" ]; then
    pass "Public client (PKCE) — token_endpoint_auth_method: none"
  elif [ -n "$auth_method" ]; then
    pass "Confidential client — token_endpoint_auth_method: $auth_method"
  fi
}

validate_archetype() {
  local file="$1"
  local name
  name="$(basename "$file" .json)"
  section "archetype: $name"

  if ! jq empty "$file" 2>/dev/null; then
    fail "Invalid JSON: $file"
    return
  fi
  pass "Valid JSON"

  require_field "$file" '.archetype'   "archetype"
  require_field "$file" '.service.id'  "service.id"
  require_array "$file" '.tiers'       "tiers"

  # Every tier must have: level, role, slug_template
  local bad_tiers
  bad_tiers="$(jq -r '.tiers[] | select(.level == null or .role == null or .slug_template == null) | .role // "UNNAMED"' "$file")"
  if [ -n "$bad_tiers" ]; then
    fail "Tiers missing required fields (level, role, slug_template): $bad_tiers"
  else
    local tier_count
    tier_count="$(jq '.tiers | length' "$file")"
    pass "All $tier_count tiers have required fields"
  fi

  # Tier 0 should exist (service root)
  local has_root
  has_root="$(jq '[.tiers[] | select(.level == 0)] | length' "$file")"
  if [ "$has_root" -eq 0 ]; then
    fail "No tier at level 0 (service root)"
  else
    pass "Has service root tier (level 0)"
  fi
}

# ── Credential validators ──

validate_service_creds() {
  local file="$1"
  section "credentials: $(basename "$file")"

  if [ ! -f "$file" ]; then
    warn "Not yet created (run step 01)"
    return
  fi

  if ! jq empty "$file" 2>/dev/null; then
    fail "Invalid JSON: $file"
    return
  fi
  pass "Valid JSON"

  require_field "$file" '.service'               "service"
  require_field "$file" '.organization.id'       "organization.id"
  require_field "$file" '.organization.slug'     "organization.slug"
  require_field "$file" '.admin.email'           "admin.email"
  require_field "$file" '.admin.password'        "admin.password"
  require_field "$file" '.admin.user_id'         "admin.user_id"
  require_field "$file" '.api_key.id'            "api_key.id"
  require_field "$file" '.api_key.key'           "api_key.key"

  # API key should match expected prefix
  local key
  key="$(jq -r '.api_key.key // empty' "$file")"
  if [ -n "$key" ] && ! echo "$key" | grep -qE '^ab0t_sk_'; then
    warn "API key does not start with 'ab0t_sk_' prefix"
  fi

  # Check org ID is UUID format
  local org_id
  org_id="$(jq -r '.organization.id' "$file")"
  if echo "$org_id" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
    pass "organization.id is valid UUID"
  else
    fail "organization.id is not a valid UUID: $org_id"
  fi
}

validate_oauth_creds() {
  local file="$1"
  section "credentials: $(basename "$file")"

  if [ ! -f "$file" ]; then
    warn "Not yet created (run step 02)"
    return
  fi

  if ! jq empty "$file" 2>/dev/null; then
    fail "Invalid JSON: $file"
    return
  fi
  pass "Valid JSON"

  require_field "$file" '.client_id'              "client_id"
  require_array "$file" '.redirect_uris'          "redirect_uris"
  require_field "$file" '.org_id'                 "org_id"

  # registration_access_token needed for update mode
  local rat
  rat="$(jq -r '.registration_access_token // empty' "$file")"
  if [ -n "$rat" ]; then
    pass "Has registration_access_token (update mode available)"
  else
    warn "No registration_access_token — cannot update client, only re-register"
  fi
}

validate_end_users_creds() {
  local file="$1"
  section "credentials: $(basename "$file")"

  if [ ! -f "$file" ]; then
    warn "Not yet created (run step 04 or 09)"
    return
  fi

  if ! jq empty "$file" 2>/dev/null; then
    fail "Invalid JSON: $file"
    return
  fi
  pass "Valid JSON"

  require_field "$file" '.org_id'            "org_id"
  require_field "$file" '.org_slug'          "org_slug"
  require_field "$file" '.parent_org_id'     "parent_org_id"
  require_field "$file" '.hosted_login_url'  "hosted_login_url"
  require_field "$file" '.permission_model'  "permission_model"
  require_array "$file" '.default_permissions' "default_permissions"

  local model
  model="$(jq -r '.permission_model' "$file")"
  case "$model" in
    team-inherited|org-inherited) pass "permission_model: $model" ;;
    *) warn "Unknown permission_model: $model (expected team-inherited or org-inherited)" ;;
  esac
}

# ── Cross-file consistency ──

validate_cross_file() {
  local perms_file="$SETUP_DIR/config/permissions.json"

  section "Cross-file consistency"

  # Find any service credential file
  local service_id creds_file
  service_id="$(jq -r '.service.id // empty' "$perms_file" 2>/dev/null)"
  if [ -z "$service_id" ]; then
    warn "Cannot check cross-file — service.id missing from permissions.json"
    return
  fi

  # Find credential file (try both naming patterns)
  for suffix in "" "-dev"; do
    for pattern in "$service_id" "integration-service"; do
      local candidate="$SETUP_DIR/credentials/${pattern}${suffix}.json"
      if [ -f "$candidate" ]; then
        creds_file="$candidate"
        break 2
      fi
    done
  done

  if [ -z "${creds_file:-}" ]; then
    warn "No credential file found — skipping cross-file checks"
    return
  fi

  # service.id in permissions.json should match .service in credentials
  local creds_svc
  creds_svc="$(jq -r '.service // empty' "$creds_file")"
  if [ "$service_id" = "$creds_svc" ]; then
    pass "service.id matches across permissions.json and $(basename "$creds_file")"
  else
    fail "service.id mismatch: permissions.json='$service_id' vs $(basename "$creds_file")='$creds_svc'"
  fi

  # service.audience in permissions.json should match .service_audience in credentials
  local perm_aud creds_aud
  perm_aud="$(jq -r '.service.audience // empty' "$perms_file")"
  creds_aud="$(jq -r '.service_audience // empty' "$creds_file")"
  if [ -n "$perm_aud" ] && [ -n "$creds_aud" ]; then
    if [ "$perm_aud" = "$creds_aud" ]; then
      pass "service.audience matches: $perm_aud"
    else
      fail "service.audience mismatch: permissions.json='$perm_aud' vs $(basename "$creds_file")='$creds_aud'"
    fi
  fi

  # Check end-users default_permissions match permissions.json default_grant: true
  local eu_file
  for suffix in "" "-dev"; do
    local candidate="$SETUP_DIR/credentials/end-users-org${suffix}.json"
    if [ -f "$candidate" ]; then
      eu_file="$candidate"
      break
    fi
  done

  if [ -n "${eu_file:-}" ]; then
    local expected_count actual_count
    expected_count="$(jq '[.permissions[] | select(.default_grant == true)] | length' "$perms_file")"
    actual_count="$(jq '.default_permissions | length' "$eu_file")"
    if [ "$expected_count" = "$actual_count" ]; then
      pass "default_permissions count matches ($actual_count)"
    else
      warn "default_permissions count mismatch: permissions.json has $expected_count default_grant:true, end-users-org has $actual_count"
    fi
  fi
}

# ──────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required" >&2
  exit 1
fi

[ "$QUIET" = true ] || echo -e "${CYAN}Auth Mesh Setup — Config Validator${NC}"

if [ -n "$SINGLE_FILE" ]; then
  # Single file mode — detect type and validate
  case "$(basename "$SINGLE_FILE")" in
    permissions*) validate_permissions "$SINGLE_FILE" ;;
    hosted-login*) validate_hosted_login "$SINGLE_FILE" ;;
    oauth-client*) validate_oauth_client "$SINGLE_FILE" ;;
    integration*|*-service*) validate_service_creds "$SINGLE_FILE" ;;
    end-users*) validate_end_users_creds "$SINGLE_FILE" ;;
    *) echo "Unknown file type: $SINGLE_FILE" >&2; exit 1 ;;
  esac
else
  # Full validation
  validate_permissions "$SETUP_DIR/config/permissions.json"
  validate_hosted_login "$SETUP_DIR/config/hosted-login.json"
  validate_oauth_client "$SETUP_DIR/config/oauth-client.json"

  # Archetypes (if they exist)
  if [ -d "$SETUP_DIR/config/archetypes" ]; then
    for f in "$SETUP_DIR/config/archetypes"/*.json; do
      [ -f "$f" ] && validate_archetype "$f"
    done
  fi

  if [ "$VALIDATE_CREDENTIALS" = true ]; then
    # Service credentials
    _svc_id="$(jq -r '.service.id // "integration"' "$SETUP_DIR/config/permissions.json" 2>/dev/null)"
    for suffix in "" "-dev"; do
      for pattern in "$_svc_id" "integration-service"; do
        _candidate="$SETUP_DIR/credentials/${pattern}${suffix}.json"
        if [ -f "$_candidate" ]; then
          validate_service_creds "$_candidate"
        fi
      done
    done

    # OAuth client credentials
    for f in "$SETUP_DIR/credentials"/oauth-client*.json; do
      [ -f "$f" ] && validate_oauth_creds "$f"
    done

    # End-users credentials
    for f in "$SETUP_DIR/credentials"/end-users-org*.json; do
      [ -f "$f" ] && validate_end_users_creds "$f"
    done

    # Cross-file consistency
    validate_cross_file
  fi
fi

# ── Summary ──
[ "$QUIET" = true ] || echo ""
if [ "$FAIL" -gt 0 ]; then
  echo -e "${RED}FAILED${NC}: $PASS passed, $FAIL failed, $WARN warnings"
  exit 1
elif [ "$WARN" -gt 0 ]; then
  echo -e "${YELLOW}PASSED${NC} with warnings: $PASS passed, $WARN warnings"
  exit 0
else
  echo -e "${GREEN}PASSED${NC}: $PASS checks passed"
  exit 0
fi
