#!/usr/bin/env bash
# authsetup v0.5.25 -> v0.5.26 checker (LMKAP/RFC-0001 §3.4). READ-ONLY: never edits TARGET.
# 0.5.26 is a security + fix release (breaking: none for normal use). This flags two things worth a look; most repos get
# "No v0.5.26 migration findings." Prints file:line, rule and fix for every candidate; exits 1 while any remain, 0 when
# clean. Prefers false positives (candidates) over false negatives — confirm each by reading the line.
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
# R1: a committed Ally install record whose file entries leave the bot folder ("../" or an absolute path as a key).
r1=$(find "$T" -name .authsetup-install.json -not -path '*/.git/*' -print0 2>/dev/null \
     | xargs -0 -r grep -HnE '"(\.\./|/)[^"]*"[[:space:]]*:' 2>/dev/null || true)
report R1 "$r1" \
  'an Ally install record names files OUTSIDE its bot folder — a tampered record (0.5.25 would act on it). Move the repo'"'"'s .claude/bots/ aside and run: authsetup bot install --project (MIGRATION.md R1).'
# R2: an environments.json in the wrapped shape the 0.5.25 docs showed — it was ignored before, it takes effect now.
r2=$(find "$T" -name environments.json -not -path '*/.git/*' -not -path '*/node_modules/*' -print0 2>/dev/null \
     | xargs -0 -r grep -HnE '"environments"[[:space:]]*:|"auth_service_url"' 2>/dev/null || true)
report R2 "$r2" \
  'environments.json in the old documented shape — ignored by <= 0.5.25, LOADED by 0.5.26: run `authsetup env` and confirm each URL is the one you mean; the simpler form is {"staging": "https://..."} (MIGRATION.md R2).'
if [ "$F" = 0 ]; then echo "No v0.5.26 migration findings."; else echo "Candidates above — see MIGRATION.md."; fi
exit $F
