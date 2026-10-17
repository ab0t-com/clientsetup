#!/usr/bin/env bash
# authsetup v0.5.27 -> v0.5.28 checker (LMKAP/RFC-0001 §3.4). READ-ONLY: never edits TARGET.
# 0.5.28 breaks nothing. This flags one thing worth a look: a service name with "_" in a permissions.json — a NEW setup
# with such a name fails at step 05 (the auth service drops "_" from org names); a setup that already works is fine.
# Prints file:line, rule and fix for every candidate; exits 1 while any remain, 0 when clean.
# Usage: ./migrate-check.sh /path/to/your/repo   (testdata/hits and testdata/clean show both outcomes)
set -u
T="${1:-.}"
F=0
hits=$(find "$T" -name permissions.json -not -path '*/.git/*' -not -path '*/node_modules/*' -print0 2>/dev/null \
       | xargs -0 -r grep -HnE '"(id|service)"[[:space:]]*:[[:space:]]*"[a-z0-9]*_[a-z0-9_]*"' 2>/dev/null || true)
if [ -n "$hits" ]; then
  echo "[R2] a service name with \"_\" — fine if this setup already works; for a NEW setup it fails at step 05. Use letters and digits only, in service.id, service.audience, registration.service and every permission prefix (MIGRATION.md R1/R2)."
  echo "$hits" | sed 's/^/  /'
  F=1
fi
if [ "$F" = 0 ]; then echo "No v0.5.28 migration findings."; else echo "Candidates above — see MIGRATION.md."; fi
exit $F
