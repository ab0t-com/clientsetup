#!/usr/bin/env bash
# authsetup v0.5.28 -> v0.5.29 checker (LMKAP/RFC-0001 §3.4). READ-ONLY: never edits TARGET.
# 0.5.29 breaks nothing for normal use. Two changes a script can notice: `backfill` no longer attempts (and 404s on) a
# workspace the service admin cannot change — it names it ("NOT changed … not a member") and exits 1 (R1); and
# `--extra-perm` refuses a platform / high / critical / privileged permission (R2). This flags scripts / CI that match the
# old text or pass --extra-perm. Prints file:line, rule and fix for every candidate; exits 1 while any remain, 0 when clean. Prefers false
# positives (candidates) over false negatives — confirm each by reading it.
# Usage: ./migrate-check.sh /path/to/your/repo   (testdata/hits and testdata/clean show both outcomes)
set -u
T="${1:-.}"
F=0
report() { # rule  hits  fix
  if [ -n "$2" ]; then
    echo "[$1] $3"
    echo "$2" | sed 's/^/  /'
    F=1
  fi
}
scan() { # extended-regex → file:line hits in scripts / CI files (never .git, node_modules, this kit)
  grep -rnIE --include='*.sh' --include='*.bash' --include='*.yml' --include='*.yaml' --include='Makefile' \
    --include='*.mk' --include='*.py' --include='Jenkinsfile' --include='*.ps1' \
    --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=v0.5.28-to-v0.5.29 -- "$1" "$T" 2>/dev/null || true
}
# R1: scripts that match the 0.5.28 backfill failure text or retry on it.
r1=$(scan 'Team not found|re-run \(idempotent\)|workspace\(s\) failed')
report R1 "$r1" \
  'matches the 0.5.28 backfill failure text. 0.5.29 changes only the workspaces your service admin can change; the rest are named "NOT changed: workspace … not a member …" and the run exits 1 with "a re-run will not change them". Branch on the exit code; never retry on it; the workspace owner applies the change (MIGRATION.md R1).'
# R2: every backfill --extra-perm — 0.5.29 refuses a platform / high / critical / privileged permission there.
r2=$(scan 'backfill[^#]*--extra-perm|--extra-perm[^#]*backfill')
report R2 "$r2" \
  'passes --extra-perm to backfill. 0.5.29 refuses a platform, risk_level high/critical or privileged permission (it would land on every workspace member, incl. future invitees). Check each id in permissions.json; grant a risky one to one person instead (MIGRATION.md R2).'
if [ "$F" = 0 ]; then echo "No v0.5.29 migration findings."; else echo "Candidates above — see MIGRATION.md."; fi
exit $F
