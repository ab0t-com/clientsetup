# authsetup 0.5.26: please upgrade (security fix)

**Upgrade now:** `authsetup update`. Nothing breaks in normal use.

**Security.** In 0.5.25, `authsetup bot install --project` / `bot uninstall --project` trusted the install record that
sits in the repository (`.claude/bots/authmesh/.authsetup-install.json`). A crafted record in a repository you cloned
could make `bot uninstall --project` delete or move files outside that folder. In 0.5.26 the record is treated as
untrusted: anything pointing outside the bot folder is ignored and reported, and symlinked backup or project folders
are refused. If you ran `bot uninstall --project` in a repository you did not create, check the files next to it.

**Also in this release:**
- `~/.authmesh/environments.json` written in the shape our docs showed (`{"environments": {"staging":
  {"auth_service_url": "https://…"}}}`) now loads. Before, it was ignored with a confusing warning. If you have such a
  file, your override takes effect after upgrading: check it with `authsetup env`.
- Ally's pages are refreshed (`authsetup bot install`). If your backend checks permissions from `/auth/validate-token`,
  send `"include_permissions": true`; without it the list is empty.

Check a repository in one step: `./migrate-check.sh /path/to/your/repo` (from the `v0.5.25-to-v0.5.26` kit).
