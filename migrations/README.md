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
| [`v0.5.23-to-v0.5.24/`](v0.5.23-to-v0.5.24/) | Permission schema registered only by the service org; ownership refusals explained (name taken / no owner recorded) and checked before anything is created; NEXT lines keep the target; credentials go only to the auth URL you gave (never to another origin a server points at); `doctor` signs in only with `--strict`; plus output-wording changes |
