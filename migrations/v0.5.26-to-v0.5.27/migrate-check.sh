#!/usr/bin/env bash
# authsetup v0.5.26 -> v0.5.27 checker (LMKAP/RFC-0001 §3.4). READ-ONLY: never edits TARGET.
# 0.5.27 is a usability release (breaking: none for normal use). ONE behaviour change a script can notice: run/up now MINT a
# new service key where 0.5.26 stopped on a revoked one (R1). This flags scripts and CI that parse the old text or rely on
# the old stop; most repos get "No v0.5.27 migration findings." Prints file:line, rule and fix for every candidate; exits 1
# while any remain, 0 when clean. Prefers false positives (candidates) over false negatives — confirm each by reading it.
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
    --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=v0.5.26-to-v0.5.27 -- "$1" "$T" 2>/dev/null || true
}
# R1: CI that parses the 0.5.26 revoked-key failure text (gone in 0.5.27: run re-mints the key and exits 0).
r1=$(scan 're-mint \(rotate the key|run step 01 on fresh creds|fresh creds|failed validation: API key|service API key already provisioned')
report R1 "$r1" \
  'parses the 0.5.26 dead-key text — 0.5.27 RE-MINTS a revoked key and exits 0. Alert on "your saved service key no longer works (revoked or deleted) — minted" (or --json .service_key.reminted) and deploy the new key: authsetup --env <env> settings --env-file .env (MIGRATION.md R1).'
# R2: status drift text whose NEXT changed for a revoked key / an unanswered key check (exit 1 now).
r2=$(scan 'reconcile the provider-pipeline drift')
report R2 "$r2" \
  'greps status NEXT text — for a revoked key it now reads "no longer works (revoked or deleted)"; a key check auth did not answer exits 1 (not 3). Branch on the exit code (MIGRATION.md R2).'
# R3: run/up --json whose stdout is fed to a TEXT tool — stdout is now one JSON document (human text on stderr).
r3=$(scan 'authsetup[^|#]*[[:space:]](run|up)([[:space:]][^|#]*)?--json[^|#]*\|[[:space:]]*(grep|sed|awk|tail|head|cut)|authsetup[^|#]*--json[^|#]*[[:space:]](run|up)([[:space:]][^|#]*)?\|[[:space:]]*(grep|sed|awk|tail|head|cut)')
report R3 "$r3" \
  'run/up --json now prints ONE JSON document on stdout (human lines on stderr); `up --json` without --yes only plans. Parse it with jq (.exit_code, .steps[], .service_key) or drop --json (MIGRATION.md R3).'
# R4: exact 0.5.26 phrases that 0.5.27 rewords.
r4=$(scan 'pure-consumer mode|\(built-in\)|they must agree \(drop one\)|never guesses production — pass --env|~ re-sent: register permission schema|~ re-sent: PUT login-config|undeclared \(auth classifies|all connections LIVE|choose a different registration\.service')
report R4 "$r4" \
  'greps a phrase 0.5.27 rewords (see the MIGRATION.md R4 table for the new text) — branch on the exit code instead.'
if [ "$F" = 0 ]; then echo "No v0.5.27 migration findings."; else echo "Candidates above — see MIGRATION.md."; fi
exit $F
