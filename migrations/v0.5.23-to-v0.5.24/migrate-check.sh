#!/usr/bin/env bash
# authsetup v0.5.23 -> v0.5.24 checker (LMKAP/RFC-0001 §3.4). READ-ONLY: never edits TARGET.
# Prints file:line, rule and fix for every candidate; exits 1 while any remain, 0 when clean.
# Prefers false positives (candidates) over false negatives — confirm each by reading the line.
# Usage: ./migrate-check.sh /path/to/your/repo   (testdata/hits and testdata/clean show both outcomes)
set -u
T="${1:-.}"
F=0
scan() { # rule  regex  fix
  local hits
  hits=$(grep -rnIE --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=vendor "$2" "$T" 2>/dev/null || true)
  if [ -n "$hits" ]; then
    echo "[$1] $3"
    echo "$hits" | sed 's/^/  /'
    F=1
  fi
}
scan R2 'register permission schema on (end-users|consumers) org|register permission schema for "[^"]*"$|admin surface \(schema owner\)' \
  'parses an authsetup schema line whose wording changed — branch on the exit code (and, if you must, "nothing to do"); there is no machine-readable equivalent yet (MIGRATION.md R2).'
scan R3 'only its owner or a platform admin can change it"' \
  'matches the auth 403 detail EXACTLY — it gained a suffix; branch on error_code == "REGISTRY_NOT_OWNER" and read owner_org_id (MIGRATION.md R3).'
scan R4 'PERM_SCHEMA#|ORG_SERVICES#' \
  'reads registry rows directly — the per-org copy for end-users/consumers orgs is no longer written (MIGRATION.md R4).'
scan R5 'HTTP 403|owned by another organi[sz]ation|set_schema_owner|authsetup run 01`' \
  'detects the schema-ownership failure by text authsetup no longer prints — treat exit code 1 as the signal; match "is taken" / "no owner recorded" to tell the cases apart (MIGRATION.md R5).'
scan R10 '✓ PUT login-config|step\(s\) not reached|would: deferred|── Run summary ──' \
  'parses a run-summary line whose wording changed (re-sends, unreached steps, deferred steps, status summary) — use the exit code (MIGRATION.md R10).'
scan R11 'cached credentials no longer valid|another run holds|is required: .*invalid character' \
  'matches an error message that now explains itself in different words — branch on the exit code (MIGRATION.md R11).'
scan R12 'providers --json.*\| *(tail|sed|head)|update[^|]*--json.*\| *(tail|sed|head)' \
  'strips lines around `providers/update --json` — the output is now exactly one JSON document; parse it directly (MIGRATION.md R12).'
scan R15 'accept self-serve consumers|signup DISABLED|consumers self-register with' \
  'parses the mesh-directory / step-08 wording that changed (closed providers, sign-up off) (MIGRATION.md R15).'
if [ "$F" = 0 ]; then echo "No v0.5.24 migration findings."; else echo "Candidates above — see MIGRATION.md."; fi
exit $F
