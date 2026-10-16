#!/usr/bin/env bash
# Fixture: the same CI script written for 0.5.24 — it branches on the exit code only.
# migrate-check.sh must report no findings here.
if ! authsetup --env dev run; then
  echo "authsetup run failed — read its output (a schema name that is taken, or no owner recorded, needs a human)"
  exit 1
fi
