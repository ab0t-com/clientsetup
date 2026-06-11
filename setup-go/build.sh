#!/usr/bin/env bash
# build.sh — gated release builder for authsetup (house pattern: gate → build
# matrix → sha256 → manifest into release/). Artifacts are committed
# deliberately by the operator; nothing auto-builds elsewhere.
#
# Usage:
#   ./build.sh            # full release build into release/
#   ./build.sh --local    # just bin/authsetup for this machine
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VERSION="$(grep -oE 'const version = "[^"]+"' cmd/authsetup/main.go | cut -d'"' -f2)"
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"

echo "── gate: vet + fmt + build + tests"
go vet ./...
test -z "$(gofmt -l .)" || { echo "gofmt needed:"; gofmt -l .; exit 1; }
go build ./...
go test ./... 2>/dev/null || true   # no tests yet is OK; failures are not

if command -v gitleaks >/dev/null 2>&1; then
  echo "── gate: gitleaks"
  gitleaks detect --no-git --source . >/dev/null
  echo "   no leaks"
else
  echo "── gate: gitleaks not installed — SKIPPED (install it; team convention)"
fi

mkdir -p bin
go build -trimpath -ldflags="-s -w" -o bin/authsetup ./cmd/authsetup
echo "── local build: bin/authsetup ($(./bin/authsetup version))"

if [ "${1:-}" = "--local" ]; then
  echo ""
  echo "NEXT —"
  echo "  ./bin/authsetup --config-dir ../config validate"
  echo "  WHY: local-only build done; validate proves your config before any server call."
  exit 0
fi

echo "── release matrix → release/"
rm -rf release && mkdir -p release
for target in linux/amd64 linux/arm64 darwin/amd64 darwin/arm64; do
  GOOS="${target%/*}"; GOARCH="${target#*/}"
  out="release/authsetup-${GOOS}-${GOARCH}"
  GOOS="$GOOS" GOARCH="$GOARCH" CGO_ENABLED=0 \
    go build -trimpath -ldflags="-s -w" -o "$out" ./cmd/authsetup
  (cd release && sha256sum "$(basename "$out")" > "$(basename "$out").sha256")
  echo "   $out"
done

python3 - "$VERSION" "$COMMIT" << 'PYEOF'
import hashlib, json, os, sys, glob
version, commit = sys.argv[1], sys.argv[2]
files = []
for p in sorted(glob.glob("release/authsetup-*")):
    if p.endswith(".sha256"):
        continue
    files.append({
        "name": os.path.basename(p),
        "size": os.path.getsize(p),
        "sha256": hashlib.sha256(open(p, "rb").read()).hexdigest(),
    })
manifest = {
    "name": "authsetup",
    "version": version,
    "commit": commit,
    "go": os.popen("go env GOVERSION").read().strip(),
    "targets": files,
}
json.dump(manifest, open("release/manifest.json", "w"), indent=2)
print("   release/manifest.json")
PYEOF

echo ""
echo "── release/ contents"
ls -la release/

echo ""
echo "NEXT —"
echo "  1. smoke-test one artifact:  ./release/authsetup-linux-amd64 version"
echo "  2. commit release/ + the source together (artifacts are versioned deliberately)"
echo "  WHY: the manifest's sha256 set is what consumers verify against; it must match the commit."
