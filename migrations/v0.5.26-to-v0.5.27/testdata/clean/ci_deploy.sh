#!/usr/bin/env bash
# Fixture: the same CI written for 0.5.27 — it branches on the exit code and reads run --json with jq.
# migrate-check.sh must report no findings here.
doc=$(authsetup --env dev --config-dir ./config run --json 2>run.log)
rc=$?
if [ -n "$(echo "$doc" | jq -r '.service_key.reminted // empty')" ]; then
  echo "the service key was re-minted — deploying it"
  authsetup --env dev --config-dir ./config settings --env-file .env
fi
[ "$rc" = 0 ] || { echo "authsetup run failed (exit $rc) — see run.log"; exit 1; }
