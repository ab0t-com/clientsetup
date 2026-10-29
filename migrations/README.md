# migrations/

One directory per behaviour-changing authsetup release, named `vFROM-to-vTO/`, following the library migration
protocol (LMKAP / RFC-0001): each kit has

- **`MIGRATION.md`** — what changed, why, and before → after for every change.
- **`migrate-check.sh`** — a read-only checker. Point it at the repo or CI scripts that drive authsetup
  (`./migrate-check.sh /path/to/your/repo`); it prints every place that relies on the old behaviour, with the fix, and
  exits non-zero while any remain. It never edits your files.
- **`CLIENT_NOTICE.md`** — copy-pasteable notice for teams that have not started the upgrade.

authsetup is a CLI, so "call sites" are the scripts/CI that run it and parse its output — not Go imports.
Crossing several versions? Run each kit's checker in order.

| Kit | Summary |
|---|---|
| [`v0.5.28-to-v0.5.29/`](v0.5.28-to-v0.5.29/) | **Breaking: none for normal use.** `backfill` checks (read-only, dry run too) which workspaces it can change and changes only those — a workspace the service admin is not a member of is named `NOT changed … not a member` and the run exits 1 (0.5.28 attempted every one: `404 Team not found`); `--extra-perm` refuses a platform / high / critical / privileged permission; the rolled-out set adds `default_team_permissions`; `run 07` stops before any privileged-tier change when the provider admin cannot enter the customer sub-org |
| [`v0.5.27-to-v0.5.28/`](v0.5.27-to-v0.5.28/) | **Breaking: none.** authsetup never generates a service name with `_` (the auth service drops it from org names, so a new setup with one failed at step 05); `validate` warns on one (non-gating — a working setup is unaffected); Ally answers four first-setup questions (flat vs workspace-per-user, validate calls need no service key, `ADMIN_EMAIL`, choosing the name) |
| [`v0.5.26-to-v0.5.27/`](v0.5.26-to-v0.5.27/) | **Usability release (breaking: none for normal use; one behaviour change, R1).** A revoked service key is re-minted by `run`/`up` (dead entry moved to `.archive/`; a failed check never mints) — scripts that expected the old stop or parse its text are flagged; `status`/`doctor` name it with the exact command (a key check auth did not answer: `status` exit 1); `run --json` / `up --json` (one document; `up` without `--yes` only plans) + a stderr warning for an unsupported `--json`; NEXT lines keep `--env`/`--config-dir`/`--yes`; reworded messages (empty-folder doctor, env override label, `--env`/`--base-url` disagreement, `up` in CI, first schema register, admin email) |
| [`v0.5.25-to-v0.5.26/`](v0.5.25-to-v0.5.26/) | **Security fix — upgrade promptly (breaking: none for normal use).** `bot install\|uninstall --project` treats the repository's install record as untrusted (nothing outside the bot folder is ever removed, moved or written; symlinked backup/project folders refused); `environments.json` in the shape the 0.5.25 docs showed now loads (your override takes effect); Ally's pages refreshed (`validate-token` needs `include_permissions`) |
| [`v0.5.24-to-v0.5.25/`](v0.5.24-to-v0.5.25/) | **Additive (breaking: none).** `authsetup bot install\|status\|uninstall` installs Ally (the setup assistant) from the binary — offline, version-matched; `skills install` installs every bundled client skill; `update` names the Ally refresh; `destroy` help names only the env's `*.<env>.json` files (never the whole credentials folder) |
| [`v0.5.23-to-v0.5.24/`](v0.5.23-to-v0.5.24/) | Permission schema registered only by the service org; ownership refusals explained (name taken / no owner recorded) and checked before anything is created; NEXT lines keep the target; credentials go only to the auth URL you gave (never to another origin a server points at); `doctor` signs in only with `--strict`; plus output-wording changes |
