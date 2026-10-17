# Changelog

All notable changes to `authsetup`.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.5.28] — 2026-10-17 — service names without "_"; Ally answers four first-setup questions
Migration kit: `migrations/v0.5.27-to-v0.5.28/` (rows R1–R3). **Breaking: none.**
### Fixed
- **A service name with `_` no longer breaks a new setup (R1, R2).** The auth service drops `_` from the org names it
  creates (`nw_rent` → org `nwrent`), so authsetup then looked for the sign-in page `/login/nw_rent-users`, got a 404, and
  step 05 failed on the very first run. `init --publish` and every name authsetup suggests now use lowercase letters and
  digits only (`"my app"` → `myapp`, was `my_app`), and `validate` (also `--json` `warnings`) WARNS when
  `service.id` or `registration.service` contains `_`, naming the fix. It is a warning, not an error: a setup that
  already works with such a name keeps working.
### Changed
- **Ally (R3):** answers four questions first setups get stuck on — one shared users org (`flat`) or a workspace per user
  (what a backend must compare in each), whether `/auth/validate-token` needs your service key (no), what `ADMIN_EMAIL`
  is for (it receives the admin's password-reset mail — use a real, monitored mailbox), and how to choose the service
  name (letters and digits; it becomes the id, audience, registration and every permission prefix; it can't change).

## [0.5.27] — 2026-10-16 — a revoked service key recovers in one run; messages that say what to type
Migration kit: `migrations/v0.5.26-to-v0.5.27/` (rows R1–R6). **Breaking: none for normal use.** One behaviour change a
script can notice: `run`/`up` now MINT a new service key where 0.5.26 stopped (R1). Built from usability trials J1 and J10
(ticket `tickets/20261016_trial_j1_first_run_confusions/`).
### Changed
- **A revoked service key is re-minted (R1, owner-approved 2026-10-16).** When the auth service answers `valid:false` for
  the saved service key (a definite answer: revoked or deleted), step 01 moves the dead key's entry to
  `<creds>/.archive/` (0600, never deleted), mints a new key with every declared permission, saves it and says
  `your saved service key no longer works (revoked or deleted) — minted <id>; deploy it: authsetup --env <env> settings
  --env-file .env, then restart your app (it still holds the dead key)`; the run's NEXT leads with the settings line. `--dry-run` / `up --dry-run` show `re-mint service key (saved key is revoked)`. A failed CHECK (5xx,
  timeout, unreachable) keeps the stop and mints nothing: `could not check the saved service API key … — a failed check is
  not a revoked key, so nothing was re-minted`. 0.5.26 stopped with `… fix: re-mint (rotate the key; run step 01 on fresh
  creds)` and an empty NEXT. An under-permissioned key is unchanged (still a stop; SOP 14).
- **`status` and `doctor` name a revoked key** and print the exact command (`authsetup --env <env> --config-dir <dir> run`,
  then `settings --env-file .env`) instead of "drift → run". `status` exits `3` for it (run reconciles it now) and `1`
  when the key could not be checked (R2).
### Added
- **`run --json` / `up --json` (R3):** one JSON document on stdout — `{schema_version:"1", command, env, service,
  exit_code, dry_run, steps:[{id, name, status, error?, duration_ms, actions:[{description, outcome}]}], cannot_repair,
  service_key?}` (+ `applied`, `planned` for up); every human line goes to stderr. `up --json` without `--yes` only plans
  (exit 0, nothing applied). `--json` on a command without a machine view prints one stderr warning; output and exit code
  are unchanged.
- `up --help` has an ENVIRONMENT section (`ADMIN_EMAIL`, `AUTHSETUP_ENV`, `AUTHSETUP_CONFIRM_PROD`, …).
### Fixed (wording; R4–R6)
- NEXT lines keep your flags: `init --publish` (`--env`), a failed `up` (`--config-dir`, `--yes`), `status`, `doctor`, `up`'s
  closing lines (`--config-dir`).
- `doctor` in a folder with no config says `consumer only` (not "pure-consumer mode") and names both ways on:
  `init --publish` and `connect <provider>`.
- `authsetup env` labels a built-in URL that `environments.json` changed `(override: <file>)`, not `(built-in)`.
- `--env` and `--base-url` that disagree: the message says where the env's URL comes from and prints the two commands to
  paste on their own lines (keep `--env`, drop `--base-url` · or the env the URL belongs to).
- A taken schema name names ALL FOUR places the new name goes (`service.id`, `service.audience`, `registration.service`,
  every permission-id prefix) with a real example, and the one command for a starter config:
  `authsetup … init --publish --as <new> --force` (old files archived).
- `status`, converged with 0 connections: `no connections; the pipeline is converged — nothing to change on the mesh.` (not
  "all connections LIVE"), and it says it cannot see your app (after a re-mint: `settings --env-file .env` + restart).
- `init --publish`'s NEXT no longer says up "asks for the environment" when the line already carries `--env`.
- A first `PUT login-config` on an org the same run created reads `✓ PUT login-config …`, not `~ re-sent … same values`.
- `up` in a script with no environment names the dev line AND the production CI line
  (`AUTHSETUP_CONFIRM_PROD=1 authsetup --env prod … up --yes`); `use-env` is for a person at a terminal.
- A taken schema name adds how to check the owning org is yours (`authsetup whois <org>`, `authsetup accounts`).
- The plan's admin line adds `(set ADMIN_EMAIL to use a real mailbox you control)`.
- A first-ever schema register reads `✓ register permission schema …` (`+` in the up plan), not `~ re-sent … same values`.
- Step 05: an undeclared `scope` reads `optional — nothing to do`.
- `doctor --help`: the under-permissioned fix says what to edit, not "fresh creds".
- Ally (embedded, 0.5.27): index, agent, README, SOPs 03, 06, 14, 16 and GAPS updated (versions say 0.5.27; doctor/update
  contact GitHub; `/auth/authorize` needs the signed-in customer's bearer; restart the app after a re-mint); SOP 14 says `ab0t_sk_live_` is every key's prefix on every
  environment (`live` is not production).

## [0.5.26] — 2026-10-16 — security fix for `bot … --project`; environments.json shape
Migration kit: `migrations/v0.5.25-to-v0.5.26/` (rows R1–R3). **Breaking: none for normal use. Upgrade promptly (R1).**
### Security
- **`bot install|uninstall --project` can no longer touch files outside the bot folder (please upgrade from 0.5.25).**
  With `--project`, Ally and its install record (`.claude/bots/authmesh/.authsetup-install.json`) live in your
  repository, so they arrive with `git clone`. In 0.5.25 a crafted record in a repository you cloned could make
  `bot uninstall --project` delete or move files outside it (for example a key next to the checkout), and
  `--force` would follow a symlinked `.skill-backups`. The record is now treated as untrusted: entries pointing
  outside are ignored and reported, every remove/move/write is checked against the real (symlink-resolved) folder,
  and a symlinked `.skill-backups` (or, with `--project`, a symlinked `.claude`, `agents`, `skills`, `bots` or bot
  folder) is refused with a message. Normal installs are unchanged. If you ran `bot uninstall --project` in a
  repository you did not create, check the files next to it.
### Fixed
- **`environments.json` in the shape our docs showed now loads.** `docs/USAGE.md` and Ally's SOP 03 showed
  `{"environments": {"staging": {"auth_service_url": "https://…"}}}`, which authsetup ignored with a warning naming the
  wrong field — so the env stayed on its built-in URL. That shape now loads (`auth_service_url` = `url`); the docs show
  the simpler `{"staging": "https://…"}`. If you wrote the old shape, your override takes effect after upgrading —
  check with `authsetup env`. A refused entry's warning now shows the shape to write. Still URLs only: a
  secret-looking field refuses the entry, as before.

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
