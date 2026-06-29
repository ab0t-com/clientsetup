<!-- Hero art goes here once generated (assets/hero.png, 880px) — see assets/README.md -->

<h1 align="center">authsetup</h1>

<p align="center"><em>onboard any service to the ab0t Auth Mesh — one binary, three config files</em></p>

---

A single static Go binary that gives your service **real authentication** — users
can sign up, log in, and get the right permissions — without you writing a line
of auth code. You describe your service in three JSON files; `authsetup`
reconciles the Auth Mesh to match. No webhooks, no cron, no per-user grants, no
middleware.

```
  config/*.json  (desired state)         authsetup            Auth Mesh (actual state)
  ─────────────────────────────  ──reconcile──►  service org · permissions · OAuth
   permissions · oauth · login                    client · hosted login · end-users org
```

**Why it exists.** Every service needs the same things: a place to register,
an OAuth client for its frontend, a branded login page, and a pool of end-users
who get permissions automatically. Hand-rolling that against an identity
platform is where weeks go. `authsetup` makes it one command — and because it
*reconciles* rather than *creates*, the same command is how you make changes
later. Edit a config, run again.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/ab0t-com/clientsetup/main/install.sh | sh
```

The installer is POSIX sh, HTTPS-only, verifies the published sha256 before
installing, keeps the previous binary for one-step rollback, and is idempotent.
Pin a version or change the location:

```sh
REF=v0.2.0          curl -fsSL https://raw.githubusercontent.com/ab0t-com/clientsetup/main/install.sh | sh
PREFIX=$HOME/.local curl -fsSL .../install.sh | sh
```

Or grab a binary directly from [`release/`](release/) (static, no runtime deps)
and verify it against [`release/checksums.txt`](release/checksums.txt).

> **Coming from the old bash kit (`./setup`, `scripts/01-09`)?**
> Run the **one-time** `authsetup --config-dir ./config migrate` from your existing
> service directory — it imports your credentials into the binary's home so `run`
> adopts your existing service org instead of creating a duplicate. Then use
> `authsetup` normally. Full guide in **[`docs/MIGRATION.md`](docs/MIGRATION.md)**.

## Quickstart

```sh
# 1. Describe your service (copy the examples, then edit the obvious bits)
cp config/permissions.json.example  config/permissions.json
cp config/oauth-client.json.example config/oauth-client.json
cp config/hosted-login.json.example config/hosted-login.json

# 2. Check it before any server call (catches server rules locally)
authsetup --config-dir ./config validate

# 3. Preview the full plan — mutates nothing
AUTH_SERVICE_URL=https://auth.dev.ab0t.com \
  authsetup --config-dir ./config --dry-run run

# 4. Apply it
AUTH_SERVICE_URL=https://auth.dev.ab0t.com \
  authsetup --config-dir ./config run

# 5. Prove it end-to-end with a throwaway user
AUTH_SERVICE_URL=https://auth.dev.ab0t.com \
  authsetup --config-dir ./config run 06
```

> **Flag position:** global flags (`--config-dir`, `--dry-run`, `--creds-dir`)
> go **before** the subcommand: `authsetup --config-dir ./config run`, not
> `authsetup run --config-dir ./config`.

Result: a service org, your permission schema, OAuth client(s), a hosted login
page, and an end-users org whose members **auto-join a default team** and
inherit every `default_grant` permission immediately. Wire your frontend to the
printed login URL + OAuth `client_id` and you're done.

> **Next step — wire your own service.** Auth is now set up, but your service
> still needs to *verify* the tokens it receives. See
> **[`docs/INTEGRATING_YOUR_SERVICE.md`](docs/INTEGRATING_YOUR_SERVICE.md)**.

## The mental model (read this once)

`config/*.json` is **desired state**. The Auth Mesh is **actual state**. Every
command **reconciles** actual → desired and is safe to re-run — nothing is
"already done, skipping". **There is no update command: to change anything, edit
the config and `run` again.**

```
 edit config/*.json ─► validate ─► run (--dry-run first) ─► status ─► done
        ▲                                                      │
        └──────────────── drift / new requirement ◄────────────┘
```

## What you get

- **Zero per-user wiring.** Permissions flow through org membership (Google
  Zanzibar under the hood). A new signup joins the end-users org, auto-joins the
  default team, and inherits its permissions. Revoke = remove from the org.
- **Two org shapes.** `flat` (interchangeable users of a shared API) or
  `workspace-per-user` (each user is a tenant with a private org they own — the
  GitHub-namespace / Notion-personal model). One config field.
- **Reconcile, not fire-and-forget.** `status` shows drift; `run` converges it.
  Re-runnable, idempotent, lockfile-guarded.
- **Multi-environment.** `AUTH_SERVICE_URL` switches dev/prod; credentials are
  isolated per environment automatically. Same config promotes dev → prod.
- **Credentials stay out of git.** Secrets are written to
  `~/.authmesh/<service>/` (0600) by design, with a redacted compliance journal
  of every API exchange.
- **Service-to-service too.** `run 07` to consume another mesh service's API,
  `run 08` to let others consume yours.

Run `authsetup --help` for the full flag list, or see
[`docs/USAGE.md`](docs/USAGE.md).

## Repository layout

```
clientsetup/
├── install.sh      # POSIX, checksum-verified installer (curl | sh)
├── release/        # the prebuilt binaries (linux/darwin × amd64/arm64) + checksums.txt + VERSION
├── config/         # *.json.example schema references + archetypes/  (copy + edit these)
├── schema/         # JSON Schemas for every config + credential file
├── docs/           # USAGE (cookbook), MIGRATION (from the old bash kit), CLI (overview)
├── skills/         # agent skills — authsetup-cli, auth-mesh-setup, mesh-service-accounts
└── llms.txt        # bootstrap entrypoint for an AI agent
```

- [`docs/USAGE.md`](docs/USAGE.md) — every scenario: onboarding, day-2 changes, backfill, CI, recovery.
- [`skills/authsetup-cli/`](skills/authsetup-cli/) — drive the CLI from an agent.
- [`llms.txt`](llms.txt) — point an AI agent here; it bootstraps itself.

## License

MIT — see [`LICENSE`](LICENSE).
