# Migration: authsetup v0.5.28 → v0.5.29

**Breaking: none for normal use.** Upgrade (`authsetup update`) and carry on. The checker
(`./migrate-check.sh /path/to/your/repo`) flags scripts that parse the old `backfill` failure text (R1) and every
`backfill --extra-perm` call to review (R2). Most repositories get `No v0.5.29 migration findings.`

## R1 — `backfill` changes only the workspaces it can change, and names the rest
| Before (v0.5.28 and earlier) | After (v0.5.29) |
|---|---|
| `--dry-run` planned `sync workspace <ws> team <team> (+N: …)` for every out-of-date workspace; the real run then failed each with `HTTP 404: Team not found` and ended `N workspace(s) failed — re-run (idempotent)` | It checks, read-only (dry run too), which sign-in can change each team. Changeable: planned and applied (`… (as a member of the workspace)` when it switches in). Not changeable: never planned or attempted; `NOT changed: workspace <ws> team <team> (+N: …) — your service admin <email> is not a member of this workspace, and the auth service changes a team only for a sign-in to the team's own org (…). A re-run of backfill will not change it: the workspace's owner (or a member holding teams.write there) has to apply it, signed in to that workspace`; exit 1 with `N workspace(s) still lack these permissions and your service admin cannot change them … a re-run will not change them`. Summary line: `… failed=N not-changeable=M` |

*Why:* the auth service changes a team only for a sign-in to the team's own org. Your end-users org may LIST a
workspace's teams, not change them, and only a member can sign in to a user's workspace. That is workspace isolation,
by design; authsetup does not work around it. It now says so instead of planning a change that cannot happen.
*Breaking?* No: the exit code is still non-zero when a workspace was not brought up to date. A script that retried
`backfill` on `re-run (idempotent)` or matched `Team not found` should read the new message: a retry cannot change a
workspace the service admin is not a member of. *Migration:* the workspace's owner applies the change, signed in to
that workspace.

## R2 — `--extra-perm` refuses a platform, high/critical-risk or privileged permission
| Before (v0.5.28) | After (v0.5.29) |
|---|---|
| any id was added to every workspace's DEFAULT team | `refusing --extra-perm: "<id>" is a high-risk permission (risk_level: high). backfill writes the workspace's DEFAULT team — every member, including people invited later — …`, before any server call (exit 1) |

*Why:* the default team is everyone in the workspace, including people invited later. `validate` already refuses such
a permission in `default_grant`, a default role or `default_team_permissions`; `--extra-perm` was the way around it.
*Breaking?* Only for a script that passed such a permission. *Migration:* grant it to the one person who needs it (the
workspace's owner, signed in to the workspace) or put it on a non-default team.

## R3 — the rolled-out set includes `default_team_permissions`
| Before (v0.5.28) | After (v0.5.29) |
|---|---|
| `default_grant` (+ `--extra-perm`) | `default_grant` ∪ `end_users.org_structure.config.default_team_permissions` (+ `--extra-perm`) — what a NEW workspace gets. A platform / high / critical / privileged id there is left out with `not backfilling "<id>": …` |

*Breaking?* No; still additive. A permission you added only to `default_team_permissions` now reaches existing
workspaces too — the `--dry-run` lists it.

## R4 — `run 07`: a privileged tier stops when the provider admin cannot enter the customer sub-org
| Before (v0.5.28) | After (v0.5.29) |
|---|---|
| The failed switch was ignored; the tier team update / member add went out with the provider-org sign-in and failed with `404 Team not found` | `privileged tier membership: the provider admin could not enter customer sub-org <id> (switch-organization: …), and the tier team's permissions and members can only be changed with a token scoped to that org — nothing was changed in the tier; re-run once the provider admin can enter it`, before any tier change |

*Breaking?* No: the run failed before too, with a misleading message. A consumer without a privileged tier is
unchanged. *Migration:* none.
