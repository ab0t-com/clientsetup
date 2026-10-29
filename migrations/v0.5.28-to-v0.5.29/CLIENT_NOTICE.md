# authsetup 0.5.29 — what changes for you

Nothing breaks for normal use. Upgrade with `authsetup update`.

- **`backfill` tells you which workspaces it can change.** The auth service changes a workspace's team only for a
  sign-in to that workspace, and a user's own workspace usually has only that user. 0.5.28 tried anyway: the dry run
  promised the change, then every workspace failed with `HTTP 404: Team not found`. 0.5.29 checks first (read-only, dry
  run included), changes the workspaces your service admin is a member of, and names the others
  (`NOT changed … not a member`) — their owners apply the change. A re-run will not change those.
- **`--extra-perm` refuses a high-risk permission** (platform, `risk_level` high/critical, privileged): backfill writes
  the default team, which is everyone in the workspace. Grant such a permission to one person instead.
- **backfill also rolls out `default_team_permissions`,** not only `default_grant`.
- **`run 07` with a privileged tier** stops with a clear message, before changing the tier, if the provider admin
  cannot enter the customer sub-org (was: `404 Team not found`).

Check a repository in one step: `./migrate-check.sh /path/to/your/repo` (from the `v0.5.28-to-v0.5.29` kit).
