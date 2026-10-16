#!/usr/bin/env bash
# Fixture: a dev teardown written against authsetup 0.5.24 help text. migrate-check.sh must flag both lines (R4, R5).
authsetup --env dev destroy --yes
rm -rf ~/.authmesh/invoicer        # 0.5.24 `destroy --help` said: rm -r <creds-dir>  (this also loses PROD credentials)
authsetup --env dev info | grep -o 'setup-go-test-[0-9]*@test-uj.example.com' | xargs -r -n1 ./remove-member.sh
