#!/usr/bin/env bash
# Fixture: CI written against authsetup 0.5.23 that parses human output and works around the old
# invalid `providers --json`. migrate-check.sh must flag every line below (R10, R12, R15).
out=$(authsetup --env dev run 2>&1)
echo "$out" | grep -q '✓ PUT login-config' && echo "login config applied"
echo "$out" | grep -q 'step(s) not reached' && echo "partial run"
authsetup --env dev providers --json | tail -n +2 | head -n -4 > providers.json
authsetup --env dev providers | grep -q 'signup DISABLED' && echo "closed provider"
