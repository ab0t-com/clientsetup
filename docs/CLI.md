# authsetup (setup-go) — the Auth Mesh client onboarding & management CLI

> **One sentence:** edit one JSON file that describes your service's
> permissions and users, run one binary, and your service has working
> authentication, authorization, hosted login, and OAuth on the Auth Mesh —
> re-run the same binary forever to apply any change.

This directory is the Go rewrite of the bash setup kit at the repository
root. It is **the main entry point for clients joining the mesh**, designed to
be operated equally well by a **human**, a **CI pipeline**, or an **AI agent**.

---

## Who this is for

| You are… | You use… |
|---|---|
| **A service team onboarding to the Auth Mesh** (internal or external company) | the Quick start below; you should never need to read auth-service internals |
| **An AI agent** asked to set up / fix / update a client's auth | the bundled skill: [`Skills/authsetup-cli/SKILL.md`](../Skills/authsetup-cli/SKILL.md) — load it and follow it; everything is non-interactive-safe |
| **A CI pipeline** | `validate` + `run` with `AUTH_SERVICE_URL` + `AUTHSETUP_CREDS_DIR` env vars; exit code is the contract |
| **The platform team** | [ARCHITECTURE.md](ARCHITECTURE.md) (design + incident-traceable conventions), [docs/MIGRATION.md](docs/MIGRATION.md) (bash parity) |

**Agent skill:** this repo ships `Skills/authsetup-cli/` (Agent Skills open
standard — works in Claude Code, Codex, Gemini, opencode…). It contains the
operating model, day-2 recipes, the full control-surface reference, and a
troubleshooting fast-path. If you are an agent reading this README: **prefer
the skill**; it is the condensed, task-oriented form of everything here.

---

## The operating model (why you don't have to think)

`config/permissions.json` is the **single source of desired state**. The auth
service is the actual state. Every command **reconciles** actual → desired:

- **Nothing is "already done, skipping."** If server state matches config, a
  run is a fast no-op. If it drifted — someone hand-edited a team, a previous
  run half-failed, you added a permission — the run converges it.
- **There is no separate "update" workflow.** Day 1 and day 500 are the same
  three commands: edit config → `--dry-run run` → `run`.
- **Re-running is always safe.** Permission syncs are additive unions (the
  tool never removes a permission you granted by hand); creates detect
  existing state by querying the server, not by trusting local files.
- **Dry-run is a real plan**, diffed against the live server, not a guess.

```
            ┌────────────────────────────────────────────────────┐
            ▼                                                    │
  edit config/*.json ─► validate ─► run --dry-run ─► run ─► status ─► CONVERGED
                            │            (plan)      (apply)  (verify)
                            └ refuses to continue on invalid config
```

State machine, exhaustively: see
[`Skills/authsetup-cli/references/control-surface.md`](../Skills/authsetup-cli/references/control-surface.md).

---

## Quick start

```bash
# 0. get a binary — either build (Go ≥1.23, zero deps) or use a release artifact
cd setup-go && ./build.sh --local        # → bin/authsetup
#   or: ./release/authsetup-linux-amd64  (verify: sha256sum -c release/*.sha256)

# 1. describe your service (start from ../config/permissions.json.example)
$EDITOR ../config/permissions.json

# 2. validate (also enforces server-side rules, e.g. no hyphens in service names)
./bin/authsetup --config-dir ../config validate

# 3. plan, then apply — against dev first
export AUTH_SERVICE_URL=https://auth.dev.ab0t.com
./bin/authsetup --config-dir ../config --dry-run run
./bin/authsetup --config-dir ../config run

# 4. prove it end-to-end (registers a throwaway user, checks their permissions)
./bin/authsetup --config-dir ../config run 06
```

You now have: a service org · permission schema · OAuth client(s) (PKCE,
RFC 7591/7592-managed) · hosted login page · an end-users org whose new
signups automatically receive every `default_grant: true` permission.

**Three orgs, three audiences:** `{service}` is your master workspace (admin +
hosted login page); `{service}-users` holds your **human end users** (they
self-register at the hosted login page — there is deliberately no manual
add-user command); a later `run 08` opens a `{service}-api-consumers` org for
**other services** that call your API. "consumer" always means another service,
never a human end user.

**Commands:** `validate` · `run [step…]` · `status` · `backfill` · `info` ·
`version`. Run `authsetup help` for flags, or read the
[control surface](../Skills/authsetup-cli/references/control-surface.md).

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
- Files are 0600, per-environment (`-dev` suffix for localhost/dev), and
  byte-compatible with the bash kit, so both toolchains interoperate.
- `authsetup info` always shows where credentials live and why.
- **Compliance journal:** every server-touching command writes
  `journal/run-<ts>.jsonl` in the creds dir — the full request *and* response
  JSON of every API call, step-tagged, secrets redacted. This supersedes the
  bash kit's partial `_raw.*` capture: nothing the server said is lost.

---

## Day-2: changing things later

| You want to… | Do |
|---|---|
| add a permission for all users | add to `permissions.json` (`default_grant: true`) → `run` ; under `workspace-per-user` also `backfill` (existing private workspaces carry frozen copies until the platform's live-policy work lands) |
| change redirect URIs | edit `oauth-client.json` → `run 02` (and `run 04` for the end-users client) |
| change login branding / registration rules | edit `hosted-login.json` → `run 03` + `run 04` |
| change the default role or team name | edit `end_users.*` → `run 04` |
| see what's live vs config | `status` |
| roll out to prod after dev | same commands, `AUTH_SERVICE_URL=https://auth.service.ab0t.com` (separate credential files are kept automatically) |

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
├── internal/                api client · config+validator · creds store · steps · ui
├── README.md                ← you are here
├── ARCHITECTURE.md          design, package layout, conventions (each traces to a real incident)
└── docs/
    ├── USAGE.md             scenario cookbook (humans + agents)
    └── MIGRATION.md         bash kit → authsetup mapping, gaps, parity notes
../Skills/authsetup-cli/     agent skill (SKILL.md + control-surface reference)
```

**Known gaps (v0.2, honest):** cross-team consumer self-service (registering
with a provider you don't hold credentials for) — use the provider's step-08
`register_url`; custom `roles[]` set the default-role *name* only
(server-side role resolution is on the platform roadmap). Everything else —
including steps 07/08 and the service API key — is ported. Details:
[docs/MIGRATION.md](docs/MIGRATION.md).

## Support

Platform team: platform-team@ab0t.com · Auth service docs:
https://auth.service.ab0t.com/docs · Found a rough edge? `SUGGESTIONS.md` at
the repo root explains how to file it.
