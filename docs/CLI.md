# authsetup (setup-go) — the Auth Mesh client onboarding & management CLI

> **One sentence:** answer a few questions (or edit one JSON file) describing your
> service's permissions and users, run one binary, and your service has working
> authentication, authorization, hosted login, and OAuth on the Auth Mesh —
> re-run the same binary forever to apply any change.

This directory is the Go rewrite of the bash setup kit at the repository
root. It is **the main entry point for clients joining the mesh**, designed to
be operated equally well by a **human**, a **CI pipeline**, or an **AI agent**.

---

## Who this is for

| You are… | You use… |
|---|---|
| **A service team onboarding to the Auth Mesh** (internal or external company) | the Quick start below (`init --publish` → `up`); you should never need to read auth-service internals |
| **A person using Claude Code** who wants a guide | `authsetup bot install` — Ally, the setup assistant (an agent + 17 plain-language SOPs + skills), installed offline from the binary and matched to its version; then say `@agent-ally` in a new session (`authsetup bot status` / `bot uninstall`; `--project` for one repository) |
| **An AI agent** asked to set up / fix / update a client's auth | the agent skills shipped inside the binary: `authsetup skills install` puts them where agents look (`authsetup skills print authsetup-cli` shows it; Agent Skills standard — Claude Code, Codex, Gemini, opencode…). Load it and follow it; everything is non-interactive-safe |
| **A CI pipeline** | `--env <name>` + `validate` + `run` (or `up --yes`), with `AUTHSETUP_CREDS_DIR`; the exit code is the contract (below) |
| **The platform team** | [ARCHITECTURE.md](ARCHITECTURE.md) (design + incident-traceable conventions), [docs/MIGRATION.md](docs/MIGRATION.md) (bash parity), [migrations/](migrations/README.md) (per-release upgrade kits) |

---

## The operating model (why you don't have to think)

`config/permissions.json` is the **single source of desired state**. The auth
service is the actual state. Every command **reconciles** actual → desired:

- **Nothing is "already done, skipping."** If server state matches config, a
  run is a fast no-op and says so. If it drifted — someone hand-edited a team, a
  previous run half-failed, you added a permission — the run converges it.
- **There is no separate "update" workflow.** Day 1 and day 500 are the same:
  edit config → `up` (or `--dry-run run` → `run`).
- **Re-running is always safe.** Creates detect existing state by querying the
  server, not by trusting local files. The end-users default team is synced
  additively (step 04 never removes a permission you granted by hand); the
  consumer tier teams of step 08 are reconciled to the config exactly.
- **Dry-run is a real plan**, diffed against the live server, not a guess. A
  schema name another organization already owns is caught before anything is
  created.
- **You never land on production by accident.** `up` asks which environment
  (never guesses production); every NEXT line repeats the `--env` you used.

```
            ┌────────────────────────────────────────────────────┐
            ▼                                                    │
  edit config/*.json ─► validate ─► up  (or --dry-run run ─► run) ─► status ─► CONVERGED
                            │       (plan in plain words → yes → apply)
                            └ refuses to continue on invalid config
```

---

## Quick start

```bash
# 0. get the binary (prebuilt; or build: cd setup-go && ./build.sh --local → bin/authsetup)
curl -fsSL https://raw.githubusercontent.com/ab0t-com/clientsetup/main/install.sh | sh

# 1. describe your service — a few questions, a starter config/ written and validated
authsetup init --publish

# 2. plan in plain words → yes → apply (asks for the environment once; --env dev to skip the question)
authsetup up

# 3. wire your app to it
authsetup --env dev settings --env-file .env     # your app's values into .env (the key is written, never printed)
authsetup --env dev snippet login > login.html   # a ready sign-in block for your page
authsetup --env dev login-url --check            # your users' sign-in page, checked
```

You now have: a service org · permission schema · OAuth client(s) (PKCE,
RFC 7591/7592-managed) · hosted login page · an end-users org whose new
signups automatically receive every `default_grant: true` permission.

**Expert path** (the numbered pipeline, unchanged): `validate` → `--env dev --dry-run run` → `--env dev run`
→ `run 06` (a throwaway user signs up, is checked for your default permissions, then removed).

**Three orgs, three audiences:** `{service}` is your master workspace (admin +
hosted login page); `{service}-users` holds your **human end users** (they
self-register at the hosted login page — there is deliberately no manual
add-user command); step 08 opens a `{service}-api-consumers` org for **other
services** that call your API (listed in the mesh directory; self-serve sign-up
for them is off until you set `registration.signup_enabled` in
`api-consumers.json`). "consumer" always means another service, never a human.

**Commands** (`authsetup --help` for all; `authsetup <command> --help` for one):
`init` · `up` · `settings` · `snippet` · `login-url` · `validate` · `run [step…]` ·
`status` · `doctor` · `backfill` · `providers` · `connect` · `disconnect` ·
`connection` · `destroy` · `info` · `whois` · `env` · `use-env` · `update` · `skills` · `version`.

**Exit codes:** `0` success / converged · `1` failed (the message says what and
what to do) · `2` unknown flag · `3` drift found by `status` (re-run reconciles)
· `4` drift authsetup cannot repair itself (needs a human; the object is named).
Read verbs with `--json`: `status` · `doctor` · `info` · `validate` · `providers`
· `whois` · `settings` · `login-url` · `connection` · `platform-holders` · `update`.

---

## Credentials: named, out-of-repo, by default

Generated secrets and state JSON (admin password, API tokens, org ids) go to
**`~/.authmesh/<service-id>/`** — a named per-service directory **outside any
git repository**. This is deliberate: the previous system wrote them into the
setup repo itself, and they ended up in commits.

- Override: `--creds-dir DIR` or `AUTHSETUP_CREDS_DIR=DIR`.
- If you point it at a path inside a git repo that is **not** gitignored,
  mutating commands stop: interactively you're offered a one-keystroke
  `.gitignore` append; non-interactively (CI/agents) you must choose
  `--write-gitignore` (recommended) or `--unsafe-creds-in-repo`.
- Files are 0600, one per environment (`<name>.<env>.json`, e.g.
  `<service>.dev.json`), and byte-compatible with the bash kit.
- `authsetup info` always shows where credentials live and why.
- **Compliance journal:** every server-touching command writes
  `journal/run-<ts>.jsonl` in the creds dir — the full request *and* response
  JSON of every API call, step-tagged, secrets redacted.

---

## Day-2: changing things later

| You want to… | Do |
|---|---|
| add a permission for all users | add to `permissions.json` (`default_grant: true`) → `up` ; under `workspace-per-user` also `backfill` (existing private workspaces carry frozen copies until the platform's live-policy work lands) |
| change redirect URIs | edit `oauth-client.json` → `up` (or `run 02` + `run 04`) |
| change login branding / registration rules | edit `hosted-login.json` → `up` (or `run 03` + `run 04`) |
| change the default role or team name | edit `end_users.*` → `up` (or `run 04`) |
| see what's live vs config | `status` · where am I / what's blocking me: `doctor` |
| roll out to prod after dev | the same commands with `--env prod` (separate credential files are kept automatically) |
| upgrade authsetup | `authsetup update`; read the release's kit in [migrations/](migrations/README.md) |

The full scenario cookbook — including org-structure choices
(`flat` vs `workspace-per-user`), customization points, CI and agent
automation patterns — is in **[docs/USAGE.md](docs/USAGE.md)**.

---

## What's here

```
setup-go/
├── bin/authsetup            local build (make build / build.sh --local)
├── release/                 versioned artifacts: linux+darwin × amd64+arm64,
│                            .sha256 per file, manifest.json
├── build.sh                 gated release builder (vet/fmt/tests/gitleaks → matrix → manifest)
├── cmd/authsetup/           CLI entry
├── internal/                api client · config+validator · creds store · steps · ui · skills (the bundled agent skill)
├── migrations/              one upgrade kit per behaviour-changing release
├── README.md                ← you are here
├── ARCHITECTURE.md          design, package layout, conventions (each traces to a real incident)
└── docs/
    ├── USAGE.md             scenario cookbook (humans + agents)
    └── MIGRATION.md         bash kit → authsetup mapping, gaps, parity notes
```

**Known gaps (honest):** cross-team consumer self-service (registering with a
provider you don't hold credentials for) — use the provider's step-08
`register_url` or `connect`; custom `roles[]` set the default-role *name* only
(server-side role resolution is on the platform roadmap); the mesh directory
does not publish a provider's per-environment service URL (off production,
`connect` says so instead of guessing). Details: [docs/MIGRATION.md](docs/MIGRATION.md).

## Support

Platform team: platform-team@ab0t.com · Auth service docs:
https://auth.service.ab0t.com/docs · Found a rough edge? `SUGGESTIONS.md` at
the repo root explains how to file it.
