# authsetup 0.5.25 — what changes for you

Nothing breaks. authsetup 0.5.25 can now install **Ally**, the setup assistant for Claude Code (an agent that walks
you through authsetup in plain words, with 17 short how-to pages and the skills it uses), straight from the binary:

```sh
authsetup update             # get 0.5.25
authsetup bot install        # Ally into ~/.claude — offline, the version that matches your authsetup
authsetup bot status         # later: still the same version? did anything change?
```
Then start a new Claude Code session and say `@agent-ally` (or "put my service on the mesh"). `--project` installs
Ally into the current repository's `./.claude/` instead; `--dry-run` shows what it would do. A file you changed is never
overwritten without `--force`, and even then it is moved to `~/.ab0t/bots/.skill-backups/`, never deleted.
`authsetup bot uninstall` removes only what `bot install` put there.

Also in this release:
- `authsetup skills install` installs **every** bundled client skill (not only `authsetup-cli`), then points you at
  `authsetup bot install`.
- After `authsetup update`, you are told to run `authsetup bot install` when your Ally came from an older authsetup.
- `destroy` now says to move only that environment's credential files (`*.<env>.json`) aside — never the whole
  `~/.authmesh/<service>/` folder, which also holds your production credentials. If a runbook of yours removes that
  folder after a `destroy`, fix it.

Check your repo in one step: `./migrate-check.sh /path/to/your/repo` (from the `v0.5.24-to-v0.5.25` kit). Almost
everyone gets `No v0.5.25 migration findings.`
