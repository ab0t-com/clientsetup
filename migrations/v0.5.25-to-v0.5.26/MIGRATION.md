# Migration: authsetup v0.5.25 → v0.5.26

**Breaking: none for normal use. Upgrade promptly: this release has a security fix (R1).** Run `authsetup update`, then,
if a repository of yours carries Ally (`bot install --project`), run `authsetup bot status --project` there. The checker
(`./migrate-check.sh /path/to/your/repo`) flags the two things worth a look (R1, R2). Most repositories get
`No v0.5.26 migration findings.`

## R1 — `bot install|uninstall --project` never touches anything outside the bot folder (security)
| Before (v0.5.25) | After (v0.5.26) |
|---|---|
| The install record (`.claude/bots/authmesh/.authsetup-install.json`) was trusted as written. With `--project` the record lives in the repository, so it arrives with `git clone`. A crafted record could make `bot uninstall --project` delete or move files OUTSIDE the bot folder, or remove a symlink elsewhere. `--force` followed a symlinked `.skill-backups` folder. | The record is untrusted input. Entries that point outside the bot folder (a `..` or absolute file path; a link not directly in `.claude/agents` or `.claude/skills`, or not pointing into the bot folder) are ignored and reported: `leave … install record entry points outside the bot folder — ignored (the record may have been tampered with)`. Every write, remove and move is checked against the real, symlink-resolved folder. A symlinked `.skill-backups`, or with `--project` a symlinked `.claude`, `.claude/agents`, `.claude/skills`, `.claude/bots` or bot folder, is refused with a message saying what to do (exit `1`). |

*Breaking?* No for any normal install: records written by authsetup only name files inside the bot folder, and the
round trip `bot install --project` → `bot uninstall --project` is unchanged. There are new refusals for symlinked
backup or project folders; the message says to move the symlink aside.
*Migration:*
1. Upgrade.
2. If you ran `bot uninstall --project` (or `bot install --project` over an existing record) in a repository you did not
   create, check the files next to it. Also run `git status` in it for anything unexpected under `.claude/bots/.skill-backups/`.
3. The checker flags a committed record that names `../` or absolute file paths. That is a tampered record: delete the
   repository's `.claude/bots/` and run `authsetup bot install --project` again.

## R2 — `environments.json` in the shape the 0.5.25 docs showed now loads
| Before | After |
|---|---|
| `docs/USAGE.md` and Ally's SOP 03 showed `{"environments": {"staging": {"auth_service_url": "https://…"}}}`. authsetup ignored that shape with a warning that named the wrong field (`ignoring env "environments" … refusing field "staging"`), so the env stayed on its built-in URL (or was unknown). | That shape loads (`auth_service_url` means the same as `url`). The docs now show the simpler `{"staging": "https://…"}`. A refused entry's warning ends with the shape to write: `— write it as {"staging": "https://…"} (URLs only)`. Fields that look like secrets still refuse the entry, as before. |

*Breaking?* Only in what you intended: if you wrote the old documented shape, **your override now takes effect**. For
example, an overridden `dev` URL is now used where the built-in was used before.
*Migration:* the checker lists every `environments.json` in that shape. Run `authsetup env` and confirm each URL is
the one you mean.

## R3 — Ally's pages (embedded copy) updated
`bot install` refreshes Ally to this version's pages:
- **SOP 06, backend recipe ("any language"):** `POST /auth/validate-token` needs `"include_permissions": true`, or it answers
  `"permissions": []` even for a user who has permissions. The page now gives the 401 / 403 / 503 rule.
- **SOP 06, sign-up calls:** the hosted page's two calls are on the USERS org's slug,
  `POST <auth>/organizations/<users-slug>/auth/register` and `…/auth/login`, with a curl test.
- **SOP 03:** the `environments.json` example (R2).
- **SOP 14:** the revoke step uses your environment's URL, not a hard-coded host.

*Breaking?* No. *Migration:* `authsetup bot install` (and `--project` where you use it). If your backend was built from
SOP 06's old recipe and checks `permissions`, add `"include_permissions": true` to its validate call.
