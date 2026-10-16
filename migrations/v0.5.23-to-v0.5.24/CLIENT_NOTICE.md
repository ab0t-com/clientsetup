# authsetup 0.5.24 — what changes for you

authsetup 0.5.24 registers your service's permission schema **only as your service org**. Steps `04` and `08` no longer
re-register it from the end-users or consumers org — that re-register was refused by the auth service (403) and could
stop step `04` before your sign-in client was updated. It also checks the schema name **before** step `01` creates
anything, explains every ownership refusal in plain words, keeps the environment in every NEXT line, and removes the
throwaway test user step `06` creates.

**Do you need to do anything?** Usually not — upgrade (`authsetup update`) and re-run as normal.

- Stuck at step 04/08 with a 403 on the permission schema? Upgrade and re-run.
- authsetup says the schema name **is taken** (another organization owns it)? Choose a different
  `registration.service` in `permissions.json` — or, if that organization is an earlier setup of this same service,
  point authsetup at that setup's credentials with `--creds-dir`.
- authsetup says the schema has **no owner recorded**? Ask the auth team to record your service org as its owner —
  re-running authsetup will not fix it.
- Scripts that detect this failure by grepping `HTTP 403` or `owned by another organization` will stop matching: treat
  exit code `1` as the signal (there is no machine-readable run output yet).
- Code that handles the auth 403 itself should branch on `error_code == "REGISTRY_NOT_OWNER"` and read `owner_org_id`,
  not the message text (this part depends on the auth-service release).
- Much of the human output is reworded to say what really happened (re-sent settings, unreached steps, who is acting
  where, what an error means and how to fix it). Exit codes are unchanged; scripts should branch on them, not on text.
- `providers --json` and `update --json` now print exactly one JSON document — drop any line-stripping workaround.
- Off production, `connect` no longer guesses the provider's URL (it used to print the production one): ask the
  provider for it.
- **Security:** authsetup now sends credentials only to the auth URL you gave it (same scheme, host and port). If your
  auth server advertises its client-management endpoint — or redirects a request — to another origin, authsetup sends
  nothing there and the step fails (exit `1`) with "the auth server at X advertises its client-management endpoint on
  Y … check that auth server's BASE_URL". This only affects a server whose public URL is set wrong (or an alias
  `--base-url`); fix the server's URL setting, or use the URL it advertises, and re-run.
- `doctor` no longer signs in by default (with stale credentials every sign-in counts toward the admin's lockout). Run
  `authsetup --env <env> doctor --strict` when you want the admin sign-in verified.

Check your repo in one step: `./migrate-check.sh /path/to/your/repo` (from the `v0.5.23-to-v0.5.24` kit).
