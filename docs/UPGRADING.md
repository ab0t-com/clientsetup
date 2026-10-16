# Upgrading authsetup

Per-version upgrade kits live in [`../migrations/`](../migrations/README.md) — one `vFROM-to-vTO/` directory per release,
each with `MIGRATION.md` (before → after), a read-only `migrate-check.sh`, and a `CLIENT_NOTICE.md`.
