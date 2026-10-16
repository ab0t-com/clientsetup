# Migration: authsetup v0.5.24 → v0.5.25

**Breaking: none.** This release is additive: a new `bot` command, a new `--project` flag, more skills from `skills
install`, and corrected help text. No existing command, flag, exit code or `--json` key changed. Upgrade
(`authsetup update`) and carry on; then, if you use Claude Code, run `authsetup bot install`. The checker
(`./migrate-check.sh /path/to/your/repo`) only looks for two things worth fixing anyway (R4, R5); it reports `No
v0.5.25 migration findings.` for almost everyone.

## R1 — `authsetup bot install | status | uninstall` (new)
| Before (v0.5.24) | After (v0.5.25) |
|---|---|
| Ally (the setup assistant: a Claude Code agent + 17 plain-language SOPs + skills) came only from the bots repo's `curl … \| sh` installer | `authsetup bot install` installs Ally from a copy **embedded in the binary** — offline, no `curl \| sh`, and the Ally that matches this authsetup version |

Layout (the same as the bots repo's installer, so Ally installed either way is identical): the folder
`~/.ab0t/bots/authmesh/`, the agent linked as `~/.claude/agents/ally.md`, each skill linked as `~/.claude/skills/<name>`
(knobs `CLAUDE_HOME`, `AB0T_BOTS_HOME`). `--project` installs under `./.claude/` (folder `./.claude/bots/authmesh/`,
relative links) so a repository can carry Ally for its team. `--dry-run` writes nothing. Re-running is a no-op. An
install record (`<bot folder>/.authsetup-install.json`: version + a checksum per file) lets `bot status` report a
changed or missing file (exit `3`) and lets `bot uninstall` remove only what it installed. A file you changed is never
overwritten silently: `bot install` stops (exit `1`, nothing written) and `bot install --force` MOVES it to
`~/.ab0t/bots/.skill-backups/` first — never deleted. An install made earlier with the bots repo's `install.sh` is
adopted (identical files need nothing; changed ones need `--force`).
*Breaking?* No — a new command. *Migration:* none; optional: `authsetup bot install`.

## R2 — `skills install` installs every bundled client skill
| Before | After |
|---|---|
| `authsetup skills install` (no name) installed `authsetup-cli` only | it installs every client skill shipped with Ally (`authsetup-cli`, `auth-mesh-setup`, `mesh-service-accounts`, `mesh-consumer-account-sop`, `billing-payment-consumer-setup`, `connect-to-ab0t-mesh-provider`, `hosted-login-setup`, `auth-hosted-login-org-config`, `authmesh-widgets`, `auth-widgets-discovery`, `auth-obo-token-exchange`, `ab0t-auth-fastapi`, `mesh-tenancy-authority`), then its NEXT names `authsetup bot install` |

The bundled `authsetup-cli` skill is now the same file as the one in the bots repo (one source): its examples carry
`--env`, and it says plain `doctor` only reads the saved admin credentials (`doctor --strict` signs in). `skills
install <name>`, `--force`, `--json` (same keys) and `skills list` / `print` work as before; `skills list` has a wider
name column and an extra line pointing at Ally. Ally's routing skill (`ally-mesh-client`) is not installable on its own
— it links to the SOPs by relative path, so it comes with `bot install`.
*Breaking?* No for every script we know of. A script that counted the folders in `~/.claude/skills/` after `skills
install` sees more of them. *Migration:* none.

## R3 — `authsetup update` says how to refresh Ally
When `authsetup bot install` installed Ally with an older authsetup, `update` adds one NEXT line:
`authsetup bot install     # refresh Ally (installed by authsetup 0.5.25) to the copy in authsetup <new>` (with
`--project` for a project install in the current folder). `update --json` is unchanged.
*Breaking?* No — NEXT is advice text. *Migration:* none.

## R4 — `destroy` help no longer suggests removing the credentials folder
| Before | After |
|---|---|
| `destroy --help` NEXT: `rm -r <creds-dir>`; a real `destroy` said "move the dir aside" | both name only that environment's files: `mkdir -p <creds-dir>/.archive && mv <creds-dir>/*.<env>.json <creds-dir>/.archive/` |

*Why:* the default credentials folder `~/.authmesh/<service>/` holds **every** environment's credentials, prod included.
Removing (or moving) the folder after destroying `dev` loses your production admin and keys.
*Breaking?* Only for a script that greps the old NEXT text ("move the dir aside"). *Migration:* if a script or runbook
removes or moves the whole credentials folder after a `destroy`, change it to move only `*.<env>.json` (the checker flags
`rm` of an `.authmesh` path).

## R5 — `up --help`: step 06 cleans up its test user (help text only)
`up --help` said "GAPS #41: cleanup is not automatic yet". Since 0.5.24 step 06 removes the `setup-go-test-…` user it
signs up (`removed test user …`); the help now says so, and what a left-over one means (an older authsetup, or a run
that printed `could not remove test user …`).
*Breaking?* No. *Migration:* drop any cleanup job you wrote for those users after you are on 0.5.24 or later (the
checker flags `setup-go-test-` in scripts as a candidate to review).

## Verify
1. `authsetup version` prints `authsetup 0.5.25`; `authsetup bot --help` exists.
2. `authsetup bot install --dry-run` lists what it would create and writes nothing; `authsetup bot install` then
   `authsetup bot status` says `up to date: Ally matches authsetup 0.5.25`.
3. `./migrate-check.sh /path/to/your/repo` reports `No v0.5.25 migration findings.`

## Rollback
Reinstall the v0.5.24 binary. Nothing on the auth service changes. An Ally installed with `bot install` keeps working
(it is plain files and links); remove it first with `authsetup bot uninstall` if you want it gone.
