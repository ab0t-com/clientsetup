#!/usr/bin/env bash
# Rolls a new default permission out to existing workspaces; a non-zero exit is read, never blindly retried.
if ! authsetup --env prod --config-dir ./config backfill; then
  echo "backfill reported workspaces it could not change — read the messages above" >&2
  exit 1
fi
