# Troubleshooting `authsetup providers` / `connect`

Write `--env` on every command; without it `authsetup` targets production.

## `providers`: `this auth service has no mesh provider directory yet (GET /mesh/providers → 404)`
The directory is not deployed on that environment. Try another (`--env dev`, `--env prod`), or use the
manual flow (`manual-http-flow.md`) with a `register_url` the provider gave you. The directory is for
discovery only; a provider can be fully usable while unlisted.

## `providers`: an empty list
No provider has opened self-serve on that environment, or every provider is unlisted
(`public_mesh: false`). If you know a provider's id, `authsetup --env dev connect <id> --as <you>`
anyway: it resolves unlisted providers by id.

## `connect`: `provider "x" did not grant every permission tier "y" requests — …`
The auth service refused to mint a key with a permission your account does not hold (subset
enforcement, the core safety property). The default tier always mints. A non-default tier needs the
provider to add your account to that tier first: connect on the default tier, ask the provider, then
`authsetup --env dev connect <id> --as <you> --tier "<name>"`.

## `connect`: `tier "x" does not publish its permission set in the directory — …`
That tier lists only a count, so `connect` cannot ask for a precise subset. Use the default tier, or ask
the provider to upgrade you after connecting.

## `connect`: `consumer account … already exists but the stored password did not authenticate — …`
The address is taken and this machine does not hold its password (another machine created it, or the
credentials file is missing). Use the machine that created it, restore its file into
`~/.authmesh/<you>/`, or pass `--email <fresh address>` to create a new consumer account.

## `connect`: `no mesh provider "<id>"`
Not in the directory and no direct record. `authsetup --env dev providers` for exact ids; check the
environment.

## `connect`: `refusing to mutate PRODUCTION (…) without an explicit target — …`
`connect` creates an account and mints a key, so it never runs against prod by default. Name the
environment: `--env dev`, or `--env prod` when you mean it. In automation that truly targets prod,
`AUTHSETUP_CONFIRM_PROD=1` is the documented switch; write down who decided it next to the pipeline.
`--dry-run` previews without changing anything.

## `connect`: `creds dir … is inside a git repo and not gitignored; …`
Your `--creds-dir` (or `AUTHSETUP_CREDS_DIR`) is inside a repository. Re-run with `--write-gitignore`,
or point the credentials outside the repository. The default `~/.authmesh/<you>/` is already safe.

## `429` / `rate limited by the auth service (~5 requests/min)`
Wait a minute and run the same command again; it adopts what it already created.

## Where is my key?
`~/.authmesh/<you>/<provider>-consumer.<env>.json` (0600), field `.api_key.key`. `connect` never prints
the value; move it into your secrets manager without echoing it. A redacted journal of every call is
in `~/.authmesh/<you>/journal/`. Never delete `~/.authmesh/<you>/`: it holds every environment.
