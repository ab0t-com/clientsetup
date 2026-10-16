#!/usr/bin/env bash
# Fixture: a CI script written against authsetup 0.5.23 that detects the schema-ownership
# failure by TEXT. migrate-check.sh must flag every line below (R5, R2).
out=$(authsetup --env dev run 2>&1)
if echo "$out" | grep -q 'HTTP 403'; then
  echo "schema owned elsewhere"
fi
if echo "$out" | grep -q 'owned by another organization'; then
  echo "ask the auth team"
fi
echo "$out" | grep -q 'admin surface (schema owner)' && echo "schema step ran"
