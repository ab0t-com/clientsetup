# Troubleshooting `authsetup providers` / `connect`

## `providers`: "no mesh provider directory yet (… → 404)"
The `GET /mesh/providers` endpoint is not deployed on the targeted auth
environment. Try another env (`--env prod` is the default; `--env dev`), or use
the raw two-call flow (`references/manual-http-flow.md`) with a `register_url`
you already know. The directory is discovery only — a provider can be fully
usable while unlisted.

## `providers`: empty list
No provider has opened self-serve (`run 08`), or every provider set
`public_mesh:false` (usable-but-unlisted). If you know a provider's id, try
`authsetup connect <id>` anyway — `connect` resolves via
`GET /mesh/providers/{id}`, which returns even unlisted providers.

## `connect`: "did not grant every permission tier … requests" (403)
The auth service refused to mint a key with a permission your tier doesn't hold
(subset enforcement — the core safety property). The **default tier** is
zero-touch and always mints. A non-default tier (e.g. "Standard") requires the
provider to add your account to that tier's team first. Connect to the default
tier, or ask the provider to upgrade you, then re-run `connect --tier "<name>"`.

## `connect`: "does not publish its permission set in the directory"
The tier you named advertises only a permission *count*, not the list, so
`connect` can't request a precise subset. Use the default tier, or use the
manual flow with permissions the provider gave you out of band.

## `connect`: "already exists but the stored password did not authenticate"
The consumer email is taken but the saved-password file isn't present (e.g. you
moved machines or lost `~/.authmesh/<self>/`). Pass `--email <fresh-addr>` to
create a new consumer, or restore the credentials file.

## `connect`: "no mesh provider <id>"
That id isn't in the directory and has no direct record. Run `authsetup
providers` for exact ids; check the environment (`--env`).

## `connect`: refuses to run against production
`connect` mutates auth (creates an account + mints a key). Give an explicit
target so it isn't a silent prod default: `--env prod` (or `AUTHSETUP_ENV=prod`,
`AUTH_SERVICE_URL=…`, or `AUTHSETUP_CONFIRM_PROD=1`). `--dry-run` previews with
no mutation and no prod prompt.

## `connect`: "creds dir … is inside a git repo and not gitignored"
Your `--creds-dir` (or `AUTHSETUP_CREDS_DIR`) resolves inside a repo. Re-run with
`--write-gitignore`, set `AUTHSETUP_CREDS_DIR` outside the repo, or (last resort)
`--unsafe-creds-in-repo`. The default `~/.authmesh/<self>/` is already safe.

## Where's my key?
In `~/.authmesh/<self>/<provider>-consumer.<env>.json` (0600), field
`.api_key.key`. `connect` never prints the value — read it from that file into
your secrets manager. A redacted call journal is under
`~/.authmesh/<self>/journal/`.
