# Changelog

All notable changes to `authsetup`.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.5.25] — 2026-10-16 — Ally, installed by the tool you already have
Migration kit: `migrations/v0.5.24-to-v0.5.25/` (rows R1–R5). **Breaking: none** — additive.
### Added
- **`authsetup bot install | status | uninstall` (R1).** Installs Ally — the auth mesh setup assistant for Claude Code
  (an agent, its routing skill, 17 plain-language SOPs, GAPS, VERSION and its companion skills) — from a copy
  embedded in the binary: offline, no `curl | sh`, and matched to this authsetup version. Same layout as the bots
  repo's installer (`~/.ab0t/bots/authmesh/`, `~/.claude/agents/ally.md` and `~/.claude/skills/<name>` as links;
  knobs `CLAUDE_HOME`, `AB0T_BOTS_HOME`), so Ally installed either way is identical. `--project` installs into
  `./.claude/` with relative links; `--dry-run` writes nothing; re-running is a no-op. An install record (version +
  a checksum per file) lets `bot status` report changed/missing files and links (exit 3) and `bot uninstall` remove
  only what it installed. A file you changed stops the install (exit 1, nothing written); `--force` moves it to
  `.skill-backups/` first — never deleted. `--json` on all three.
- `--project` flag (bot).
### Changed
- **`skills install` installs every bundled client skill (R2)**, not only `authsetup-cli`, then points at
  `authsetup bot install`. The bundled skills are now ONE copy — the bots repo's (`shared/bot/authmesh/skills/`) — so
  the binary's `authsetup-cli` skill gained `--env` on its backfill examples and the `doctor --strict` wording.
  YAML folded descriptions show in `skills list`.
- **`update` names the Ally refresh (R3)** when Ally was installed by an older authsetup.
- **Help text (R4, R5):** `destroy` no longer suggests `rm -r <creds-dir>` — it names only that env's `*.<env>.json`
  files (the folder holds every environment, prod included); `up --help` no longer says test-user cleanup is missing
  (step 06 removes its test user since 0.5.24). The top-level help lists `skills` and `bot`.
### Build
- `embed-bot.sh` (`make embed-bot`, run first by `build.sh`) copies the canonical `shared/bot/authmesh/` into
  `internal/bot/authmesh/`; a test fails when the embedded copy differs from the canonical tree (skipped, saying why,
  in a checkout without the monorepo — the committed copy then ships).

## [0.5.24] — 2026-10-16 — Schema register is owner-only and self-explaining
Migration kit: `migrations/v0.5.23-to-v0.5.24/` (rows R1–R19 referenced below).
### Security
- **Credentials go only to the auth URL you gave (R18).** authsetup no longer sends a request — and so no
  registration access token, bearer or password — to another origin (scheme + host + port) than its auth URL. An RFC
  7592 client-management URI the server advertises on another origin is not contacted: the step fails (exit 1) and
  names both origins and the likely cause (the server's `BASE_URL`). A redirect to another origin is not followed
  (Go would keep `Authorization` across a scheme/port change and re-send a `307` body — a password — to any host).
  Breaking only for a setup whose auth server advertises a different origin than the one you use — on purpose.
### Fixed
- **Permission-schema register never runs as the wrong org (R1).** The schema is a global, owner-only
  registry entry keyed by service name; the service org registers it in step 01 and owns it. Steps 04
  (end-users org) and 08 (consumers org) used to re-register it signed in as those orgs, which the
  auth service refuses (`403`) — it stranded a live consumer. Only the service org ever registers it
  now: a current schema is a verified no-op ("… — nothing to do"); a missing or out-of-date one is
  re-registered by the service org.
- **A taken schema name is caught before anything is created (R6).** Step 01 reads the public
  registry first — in a dry run too — so a name another organization owns stops the run before an
  admin account or service org is created. An unreadable registry is "unknown", never "taken".
- **Step 04 checks the schema last (R7)**, so a schema problem no longer stops the end-users sign-in
  settings and client from being updated; the step still fails (exit 1) and names the schema.
- **NEXT lines keep the target you used (R8).** A pasted NEXT line no longer drops `--env` and lands on
  production: it carries `--env <name>` (or `--base-url <url>` when the environment came from a URL),
  `--config-dir` when given, and `--as` for connect/disconnect. `validate` no longer suggests a dry run
  against production.
- **Step 06 removes its throwaway test user (R9)** after the sign-up check, so repeated runs (and every
  `up` against production) no longer leave `setup-go-test-…` accounts in your end-users org.
### Changed
- **Schema actions name their org (R2):** `register permission schema for "svc" as service org <id> —
  admin surface` once the service org exists (a first-run dry-run plan has no org id yet).
- **Ownership refusals are explained in plain words (R5)** as one of three cases — the name is taken
  (choose a different `registration.service`, or `--creds-dir` the setup that owns it), the schema has
  no owner recorded (ask the auth team; re-running will not help), or the server did not say which. The
  owner is read from the auth service's `owner_org_id` when it sends one (R3). The message no longer
  contains `HTTP 403` or "owned by another organization" — scripts should use the exit code (1).
- **Run summaries say what really happened (R10):** re-sent settings print `~ re-sent:` (not a ✓
  change) and a converged re-run says "no changes were needed"; the end line counts `N changed · M
  re-sent`; unreached steps are listed by name and the last line names the failed step, with the exact
  resume command in NEXT; a dry run's planned count equals its `would:` lines, deferred steps say what
  they wait for, and a dry run prints no ✗; `status` reads as a check; a cannot-repair step shows
  "needs you" with the redirect-URI difference and concrete options.
- **Errors explain themselves (R11):** stale admin credentials name the file, the admin and the likely
  causes; OAuth-shaped server errors read as prose; a held lock says whether its run is alive; invalid
  JSON in a config file gives the line and column.
- **One JSON document per `--json` (R12):** `providers --json` has no prelude/NEXT around it;
  `update --json` and `validate --json` report failures as JSON (`validate --json` gains an additive
  `warnings` array). An unknown flag prints one "did you mean" line instead of the whole help (exit 2,
  unchanged).
- **validate is clearer (R13):** one problem line for a bad `registration.service`, with the same id
  `init --publish` would generate; non-gating warnings for redirect URIs the server will refuse and for
  an unreadable `oauth-client.json`; local-only commands say the URL was not contacted.
- **Who acts where (R14):** "acting as <admin> in <org>" at each org switch; the saved-credentials line
  shows the real path; no config → an error, then `init --publish` in NEXT.
- **Consumers and the directory tell the truth (R15):** sign-up-off providers read "closed — invitation
  only" (no `connect` suggestion); step 08 no longer advertises self-registration when it is off; the
  derived Standard tier's description matches its permissions; off production `connect` says the
  provider URL is not published instead of printing the production one.
- **`</dev/null` is not a terminal (R16)**, so CI gets the non-interactive message straight away.
- **doctor, help, docs (R17, R19):** a non-gating `admin sign-in` row in `doctor` — it only reads the saved
  credentials by default (a stale-password sign-in counts toward the admin's lockout) and signs in once with
  `doctor --strict`; an actionable doctor NEXT;
  the help's exit-code table matches the binary; the bundled agent skill, README and USAGE are refreshed
  around `init --publish` → `up`.

## [0.5.23] — 2026-10-09 — App-to-app connections
### Added
- `authsetup connection create|list|revoke` — manage the connections that let one app act for a
  signed-in person at another mesh service (the governance layer for app-to-app access on a user's
  behalf). `create` takes `--from <app>`, `--to <resource>`, `--scope`, and an explicit
  `--consent admin|user`; `list` shows an org's connected apps; `revoke` removes a connection.
- `--dry-run`, `--yes`, and `--json` on the connection commands; clear, plain-language messages for
  every server response.

## [0.5.22] — 2026-10-09 — Easier first-run setup
### Added
- A smoother "get going" flow: `up`, `settings --env-file`, a copy-paste login snippet, `login-url`,
  `init --publish`, and human-readable names in generated config.

## [0.5.19] — 2026-10-09 — On-behalf-of actor setup
### Fixed
- `obo-actor` / `obo-enable` now provision and wire the on-behalf-of actor identity end to end.
