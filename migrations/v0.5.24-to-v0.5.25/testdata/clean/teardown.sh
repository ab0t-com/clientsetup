#!/usr/bin/env bash
# Fixture: the same teardown for 0.5.25 — only the destroyed env's files are moved aside. migrate-check.sh must pass it.
authsetup --env dev destroy --yes
mkdir -p ~/.authmesh/invoicer/.archive && mv ~/.authmesh/invoicer/*.dev.json ~/.authmesh/invoicer/.archive/
authsetup bot install
