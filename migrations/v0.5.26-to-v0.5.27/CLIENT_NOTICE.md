# authsetup 0.5.27: a revoked service key now recovers in one run

**Upgrade:** `authsetup update`. Nothing breaks in normal use.

**The one behaviour change.** If someone revokes or deletes your service's saved API key, `authsetup run` (or `up`) used to
stop with `fix: re-mint (rotate the key; run step 01 on fresh creds)` and no command to run. In 0.5.27, when the auth
service answers that the saved key is not valid, step 01 moves the dead key's entry to `~/.authmesh/<service>/.archive/`
(never deleted), mints a new key with your declared permissions and prints:

    your saved service key no longer works (revoked or deleted) — minted <id>; deploy it: authsetup --env <env> settings --env-file .env, then restart your app (it still holds the dead key)

Then deploy the new key to your backend and restart it. `--dry-run` shows `re-mint service key (saved key is revoked)` first. If the
auth service could not be reached (5xx, timeout), nothing is minted — it stops and says the check failed. `status` and
`doctor` name a revoked key and print the exact command.

**If you automate authsetup:** a CI job that expected `run` to fail on a dead key now succeeds and mints a key — alert on
the `minted` line (or `service_key.reminted` with `--json`) and deploy the new key. `status` exits `1` (not `3`) when the
key could not be checked because auth did not answer.

**Also in this release:** `run --json` / `up --json` print one JSON document (`up --json` without `--yes` only plans);
`--json` elsewhere warns on stderr; NEXT lines keep your `--env`, `--config-dir` and `--yes`; clearer messages for an
empty folder, an overridden environment URL, `--env`/`--base-url` disagreeing, `up` in CI, and the admin email.

Check a repository in one step: `./migrate-check.sh /path/to/your/repo` (from the `v0.5.26-to-v0.5.27` kit).
