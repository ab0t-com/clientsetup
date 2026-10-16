#!/usr/bin/env bash
# authsetup v0.5.24 -> v0.5.25 checker (LMKAP/RFC-0001 §3.4). READ-ONLY: never edits TARGET.
# 0.5.25 is ADDITIVE (breaking: none). This only flags two things worth fixing anyway; most repos get
# "No v0.5.25 migration findings." Prints file:line, rule and fix for every candidate; exits 1 while any remain, 0 when
# clean. Prefers false positives (candidates) over false negatives — confirm each by reading the line.
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
scan R4 '(^|[^a-z])rm[[:space:]]+(-[a-zA-Z]*[[:space:]]+)*[^[:space:]]*\.authmesh|move the dir aside' \
  'removes (or parses the old advice to move) the whole credentials folder — it holds EVERY environment, prod included; move only that env'"'"'s files: mkdir -p <dir>/.archive && mv <dir>/*.<env>.json <dir>/.archive/ (MIGRATION.md R4).'
scan R5 'setup-go-test-' \
  'cleans up step 06 test users by hand — since 0.5.24 step 06 removes the one it creates; drop the job once every runner is on >= 0.5.24 (MIGRATION.md R5).'
if [ "$F" = 0 ]; then echo "No v0.5.25 migration findings."; else echo "Candidates above — see MIGRATION.md."; fi
exit $F
