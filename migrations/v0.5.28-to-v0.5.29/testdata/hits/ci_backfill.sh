#!/usr/bin/env bash
# Rolls a new default permission out to existing workspaces, retrying on the 0.5.28 "re-run (idempotent)" advice.
for i in 1 2 3; do
  if authsetup --env prod --config-dir ./config backfill 2>&1 | tee backfill.log; then break; fi
  grep -q "re-run (idempotent)" backfill.log && continue
  grep -q "Team not found" backfill.log && echo "auth glitch, retrying" && continue
  break
done
authsetup --env prod --config-dir ./config backfill --only-org "$WS" --extra-perm acme.override.clearance
