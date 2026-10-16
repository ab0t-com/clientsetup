#!/usr/bin/env bash
# Fixture: CI written against authsetup 0.5.26 that pages on a dead service key by TEXT and parses run --json as text.
# migrate-check.sh must flag every line below (R1, R2, R3, R4).
out=$(authsetup --env dev --config-dir ./config run 2>&1)
if echo "$out" | grep -q 're-mint (rotate the key'; then
  echo "service key is dead — page the on-call"; exit 1
fi
authsetup --env dev status | grep -q 'reconcile the provider-pipeline drift' && authsetup --env dev run
authsetup --env dev --config-dir ./config run --json | grep -q 'Run summary' && echo "ran"
authsetup --env dev env | grep 'dev ' | grep -q '(built-in)' && echo "default dev"
authsetup --env dev status | grep -q 'all connections LIVE' && echo ok
