#!/usr/bin/env sh
# =============================================================================
# authsetup installer (public GitHub release)
# =============================================================================
#
# Downloads the `authsetup` binary from this GitHub repo's raw content and
# installs it, verifying the published sha256 before touching anything.
#
# What it does:
#   1. Detects host OS + arch (linux/darwin × amd64/arm64 are published).
#      Fails clearly on anything else rather than installing the wrong thing.
#   2. Downloads release/checksums.txt, then release/authsetup-<os>-<arch>,
#      over HTTPS.
#   3. Verifies the binary against the published sha256 — mandatory.
#   4. Atomically installs to $PREFIX/bin/authsetup (default /usr/local/bin),
#      keeping the prior binary as `.previous`.
#   5. Confirms with `authsetup version`.
#
# Properties (compliance):
#   - POSIX sh; runs under /bin/sh on Linux/macOS/busybox.
#   - HTTPS only — TLS verification ALWAYS on (`-k`/`--insecure` never used).
#   - sha256 verification is mandatory; refuses to install on mismatch or a
#     missing checksums.txt.
#   - No destructive operations: never `rm -rf` of user data; only writes the
#     install dir + a temp dir it creates and cleans up.
#   - Atomic install via `install`/`mv` of a fully-verified tempfile.
#   - Idempotent: re-running upgrades/downgrades; same version = no-op exit 0.
#   - Rollback: keeps one `.previous`. No telemetry, no analytics.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/ab0t-com/clientsetup/main/install.sh | sh
#
# Pin a git ref, change install dir, or point at a fork:
#   REF=v0.2.0          curl -fsSL .../install.sh | sh
#   PREFIX=$HOME/.local curl -fsSL .../install.sh | sh
#   REPO=myfork/clientsetup curl -fsSL .../install.sh | sh
#
# Exit codes: 0 installed/up-to-date · 1 user error · 2 internal error.
# =============================================================================

set -eu

# ----- knobs ----------------------------------------------------------------
NAME="authsetup"
REPO="${REPO:-ab0t-com/clientsetup}"          # GitHub "owner/repo"; override for a fork
REF="${REF:-main}"                            # git ref the raw content is served from
BASE_URL="${BASE_URL:-https://raw.githubusercontent.com/${REPO}/${REF}}"
PREFIX="${PREFIX:-/usr/local}"
INSTALL_PATH="${INSTALL_PATH:-${PREFIX}/bin/${NAME}}"

# ----- pretty print ---------------------------------------------------------
RED=""; GREEN=""; YELLOW=""; BOLD=""; RESET=""
if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
    if [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
        RED="$(tput setaf 1)"; GREEN="$(tput setaf 2)"; YELLOW="$(tput setaf 3)"
        BOLD="$(tput bold)"; RESET="$(tput sgr0)"
    fi
fi
info() { printf "%s→%s %s\n" "$BOLD" "$RESET" "$*"; }
ok()   { printf "%s✓%s %s\n" "$GREEN" "$RESET" "$*"; }
warn() { printf "%s!%s %s\n" "$YELLOW" "$RESET" "$*" >&2; }
fail() { printf "%s✗%s %s\n" "$RED"   "$RESET" "$*" >&2; exit 1; }

# ----- prerequisites --------------------------------------------------------
need() { command -v "$1" >/dev/null 2>&1 || fail "required tool missing: $1"; }
need uname
need curl
need mktemp
if   command -v sha256sum >/dev/null 2>&1; then SHA256_CMD="sha256sum"
elif command -v shasum    >/dev/null 2>&1; then SHA256_CMD="shasum -a 256"
elif command -v openssl   >/dev/null 2>&1; then SHA256_CMD="openssl_sha256"
else fail "no sha256 tool found (need one of: sha256sum, shasum, openssl)"
fi
sha256_of() {
    case "$SHA256_CMD" in
        openssl_sha256) openssl dgst -sha256 "$1" | awk '{print $NF}' ;;
        *)              $SHA256_CMD "$1" | awk '{print $1}' ;;
    esac
}

# ----- detect OS + arch -----------------------------------------------------
case "$(uname -s)" in
    Linux*)  OS="linux"  ;;
    Darwin*) OS="darwin" ;;
    *) fail "unsupported OS: $(uname -s) — published targets: linux, darwin" ;;
esac
case "$(uname -m)" in
    x86_64|amd64)  ARCH="amd64" ;;
    arm64|aarch64) ARCH="arm64" ;;
    *) fail "unsupported architecture: $(uname -m) — published targets: amd64, arm64" ;;
esac
ASSET="${NAME}-${OS}-${ARCH}"

info "Repo:         ${BOLD}${REPO}${RESET} @ ${REF}"
info "Target:       ${BOLD}${ASSET}${RESET}"
info "Install path: ${BOLD}${INSTALL_PATH}${RESET}"

# ----- resolve published version -------------------------------------------
PUBLISHED="$(curl --proto '=https' --tlsv1.2 -fsSL --max-time 15 \
    "${BASE_URL}/release/VERSION" 2>/dev/null | tr -d '\r\n[:space:]' || true)"
[ -n "$PUBLISHED" ] && info "Published version: ${BOLD}${PUBLISHED}${RESET}"

# ----- short-circuit if already at the published version --------------------
if [ -n "$PUBLISHED" ] && [ -x "${INSTALL_PATH}" ]; then
    CURRENT="$("${INSTALL_PATH}" version 2>/dev/null | head -1 | awk '{print $NF}' | tr -d '[:space:]' || true)"
    if [ -n "$CURRENT" ] && [ "$CURRENT" = "$PUBLISHED" ]; then
        ok "${NAME} ${PUBLISHED} already installed at ${INSTALL_PATH} — nothing to do."
        exit 0
    fi
    [ -n "$CURRENT" ] && info "Currently installed: ${CURRENT} → updating to ${PUBLISHED}"
fi

# ----- working dir (we own it — safe to clean up) ---------------------------
WORKDIR="$(mktemp -d 2>/dev/null || mktemp -d -t 'authsetup-install')"
[ -d "$WORKDIR" ] || fail "could not create temp dir"
cleanup() { rm -rf -- "$WORKDIR"; }
trap cleanup EXIT INT HUP TERM
BIN_TMP="${WORKDIR}/${NAME}"
SUMS_TMP="${WORKDIR}/checksums.txt"

# ----- download checksums first --------------------------------------------
info "Fetching release/checksums.txt"
curl --proto '=https' --tlsv1.2 -fsSL --max-time 60 --output "$SUMS_TMP" \
    "${BASE_URL}/release/checksums.txt" \
    || fail "could not fetch checksums.txt — refusing to install without verification"
[ -s "$SUMS_TMP" ] || fail "checksums.txt is empty — refusing to install"

# checksums.txt is "<hash>  <asset>" lines; pull the one for our platform.
EXPECTED_HASH="$(awk -v a="$ASSET" '$2 == a || $2 == "*"a { print $1; exit }' "$SUMS_TMP" | tr -d '[:space:]')"
[ -n "$EXPECTED_HASH" ] || fail "no checksum entry for ${ASSET} in checksums.txt"
case "$EXPECTED_HASH" in *[!a-fA-F0-9]*) fail "checksum entry is malformed" ;; esac
[ "${#EXPECTED_HASH}" -eq 64 ] || fail "checksum is not 64 hex chars"

# ----- download the binary --------------------------------------------------
URL="${BASE_URL}/release/${ASSET}"
info "Downloading ${URL}"
curl --proto '=https' --tlsv1.2 -fsSL --max-time 300 --output "$BIN_TMP" "$URL" \
    || fail "download failed"
[ -s "$BIN_TMP" ] || fail "downloaded file is empty"

# ----- verify ---------------------------------------------------------------
info "Verifying sha256"
ACTUAL_HASH="$(sha256_of "$BIN_TMP")"
[ "$ACTUAL_HASH" = "$EXPECTED_HASH" ] \
    || fail "checksum mismatch — expected ${EXPECTED_HASH}, got ${ACTUAL_HASH}. Aborting (no install performed)."
ok "Checksum verified"
chmod 0755 "$BIN_TMP"

# ----- install (atomic, with rollback) --------------------------------------
DEST="${INSTALL_PATH}"
DEST_DIR="$(dirname "$DEST")"
PREV="${DEST}.previous"

SUDO=""
if ! mkdir -p "$DEST_DIR" 2>/dev/null; then
    if command -v sudo >/dev/null 2>&1; then SUDO="sudo"; info "Creating ${DEST_DIR} (sudo)"; sudo mkdir -p "$DEST_DIR" || fail "cannot create ${DEST_DIR}"
    else fail "cannot create ${DEST_DIR} and sudo is unavailable"; fi
elif [ ! -w "$DEST_DIR" ]; then
    if command -v sudo >/dev/null 2>&1; then SUDO="sudo"; info "Installing to ${DEST_DIR} requires sudo"
    else fail "${DEST_DIR} is not writable and sudo is unavailable"; fi
fi

# Snapshot the current binary for one-step rollback. We never delete it.
if [ -e "$DEST" ]; then
    info "Saving current binary as ${PREV}"
    $SUDO mv -f "$DEST" "$PREV" || fail "could not snapshot existing binary"
fi

info "Installing ${NAME} → ${DEST}"
if command -v install >/dev/null 2>&1; then
    $SUDO install -m 0755 "$BIN_TMP" "$DEST" || fail "install failed"
else
    $SUDO mv -f "$BIN_TMP" "$DEST" || fail "install failed"
    $SUDO chmod 0755 "$DEST"
fi

# ----- post-install sanity --------------------------------------------------
if "$DEST" version >/dev/null 2>&1; then
    ok "Installed: $("$DEST" version 2>/dev/null | head -1)"
else
    warn "Installed binary did not respond to 'version'. Roll back with:"
    warn "  ${SUDO} mv -f \"${PREV}\" \"${DEST}\""
fi

# ----- PATH guidance --------------------------------------------------------
case ":$PATH:" in
    *":${DEST_DIR}:"*) ;;
    *) warn "${DEST_DIR} is not in your \$PATH. Add it:"; warn "  echo 'export PATH=\"${DEST_DIR}:\$PATH\"' >> ~/.profile" ;;
esac

cat <<EOF

${BOLD}Done.${RESET} ${NAME} is installed at ${DEST}.
  Next   ${BOLD}${NAME} --config-dir ./config validate${RESET}   then  ${BOLD}${NAME} --config-dir ./config --dry-run run${RESET}
  Update by re-running this installer; the previous binary is kept at
  ${PREV} for rollback:  ${SUDO} mv -f "${PREV}" "${DEST}"
EOF
exit 0
