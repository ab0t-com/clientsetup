# Suggestions

A living list of robustness, idempotency, ergonomic, and feature
improvements for the setup CLI. Open items are bugs we know about but
haven't shipped fixes for; closed items move to the changelog (or just
get deleted from this file when the PR lands).

## How to add a suggestion

You don't need to be a maintainer. Three ways, in increasing order of
weight:

1. **Open a GitHub issue** at
   https://github.com/ab0t-com/client-service-setup-cli/issues with a
   short title and the smallest reproducer you can write. This is the
   right path if you're not sure whether something is a bug, a missing
   feature, or by-design.

2. **Open a pull request** that edits this file directly. Add an item
   under the right section, link to your reproducer, and (if you have
   strong opinions) sketch the fix in 1–2 sentences. Maintainers can
   then triage during the next review pass.

3. **Open a pull request with the actual fix.** Reference the
   suggestion you're closing in the PR description. The fix gets
   merged, the suggestion gets removed.

Keep entries terse: one paragraph max per item, code locations as
`path:line` so readers can jump straight there. If something deserves
more detail (design notes, alternatives considered) put it in a
`docs/` markdown and link to it.

---

## Past trouble (already fixed — kept for context)

These were live bugs at one point. They're closed; this section exists
so future contributors recognize the *patterns* and avoid recreating
them.

| Commit | Bug | Lesson |
|---|---|---|
| `f108e7d` | Step 04 didn't update OAuth client `redirect_uris` when they drifted from config — silently used stale URLs | "Already exists, skipping" is *not* idempotent — must reconcile state |
| `0ab4b7f` | Step 07 exited 1 when no provider configs existed → blocked step 08 in `./setup run` | Optional steps must exit 0 with a message, not 1 |
| `866eb04` | Step 01 trusted cached `org_id` without verifying the server still had it; `!` in passwords broke jq escaping | Verify cached state on the server before trusting it; use `jq -n --arg` for any user-supplied string |

Pattern: every fix was a hole in the "re-run safely" promise. Each
script is one external-state assumption away from another similar
bug — assume nothing about the server's state, always verify before
acting.

---

## Open: robustness gaps

- **Inconsistent `set` flags across scripts.**
  - `scripts/06-test-end-user.sh` → `set -uo pipefail` (no `-e`)
  - `scripts/07-register-consumer.sh` → `set -e` only (no `-u`, no `-o pipefail`)
  - `scripts/__backfill-service-audience.sh` → `set -u` only (no errexit!)
  Standardize on `set -euo pipefail` everywhere.

- **Zero retry logic on HTTP calls.** A single transient network blip
  during step 04 means re-running the whole step. Adding
  `curl --retry 3 --retry-delay 2 --retry-connrefused` to every
  state-changing request would dramatically reduce manual reruns.

- **No concurrency lock.** Two operators (or two CI jobs) running
  `./setup` against the same env at the same time can race step 04's
  "check then create OAuth client" pattern. A `flock` on
  `$SETUP_DIR/.setup.lock` is one line.

- **70 instances of `|| true` / `2>/dev/null`** across scripts. Most
  are legitimate; many are not. Worth a sweep — every suppression
  site is a place where surprise hides.

- **Validator runs but doesn't gate.** `scripts/validate-config.sh`
  exists and reports failures, but `./setup run` doesn't call it as a
  precondition. Today integration's `permissions.json` is failing
  validation (permission-ID prefix mismatch + an undefined
  permission reference) and setup will run anyway. Wire validator as
  a gate with `--skip-validate` opt-out.

- **No rollback / cleanup commands.** If step 04 fails halfway through
  (after creating the team but before propagating to login_config),
  there's no `./setup clean 04` to undo. You repair by hand.

- **No "what would change" preview beyond `DRY_RUN=1`.** Dry-run
  shows the *intended* call, not a diff against current server state.
  A `./setup diff` that fetched current state and showed the
  changeset would catch entire classes of bugs.

- **Step `09` is dead code.** `__09-setup-end-users-org-inherited.sh`
  (the `__` prefix means "skipped"). It still has a `TODO` about
  per-user permissions. Either finish it, formally rename to
  `.deprecated`, or delete.

## Open: not-yet-merged improvements that exist elsewhere

- **`scripts/06-test-end-user.sh` workspace-lookup fix lives on
  sandbox-platform's clone, uncommitted upstream.** Switches the
  workspace lookup from admin-side `/organizations/{id}/hierarchy`
  (which now hides `settings` per auth ticket 20260402, Task 41) to
  the user's own `/users/me` → `organizations[]` where `role=owner`.
  Without this, `./setup run 06` will fail to find the materialized
  workspace on any platform that's pulled the auth-side OrgInfo
  settings-hiding change.

## Open: public-repo readiness (carried from `TASKLIST.md`)

These don't break functionality but block making the repo public.

- **H1: Hardcoded `/home/ubuntu/infra/...` paths in tracked files.**
- **M1: `$schema` URL in `config/api-consumers.json.example` points
  to private `auth.service.ab0t.com`.**
- **M2: Personal emails (`mike+billing@…`) in tracked docs and
  Skills.**
- **M3: `scripts/service-client-setup/README.md` leaks internal
  topology** — full mesh diagram with real service names, ports,
  admin emails.

## Open: missing entirely

- **CI / integration tests.** Validator only checks shape, not
  behavior. No end-to-end "spin up auth, run all 8 steps, verify 06
  passes" smoke test exists in the repo.

- **`./setup status` cross-environment.** Today it tells you what's
  done in the current env; doesn't help you spot drift between dev
  and prod.

- **Run summary.** `./setup run` stops at the first failure thanks to
  `set -e`, but there's no "5/8 steps succeeded, failed at step 06
  because…" report.

- **Required-tools preflight.** Scripts check for `jq` / `python3` /
  `curl` individually; no single "you're missing X" message before
  any state changes.

- **HTTP error-body surfacing.** When a step fails on a 4xx/5xx, the
  response body is sometimes printed, sometimes not. Standardize on
  always printing the JSON `detail` field.

---

## Closed (most recent first)

*(Move items here when you ship the fix. Keep one-line entries:
`commit-sha — short description`. Trim entries older than ~6 months.)*

- `(this commit)` — Steps 01/03/04/08 now persist every JSON server response under `_raw.*` (token expiries, server-canonicalized slugs, actually-granted permissions, etc.) instead of cherry-picking single fields. Top-level shape unchanged for back-compat.
- `7ab9ad7` — Step 04 persists RFC 7592 management credentials and uses them for end-users client updates
- `e87461c` — Tracked pre-push hook blocks pushes from clones populated with credentials
- `4268d0c` — Adds `org_structure.pattern` config (workspace-per-user / flat)
- `f108e7d` — Step 04 idempotency: update OAuth client redirect_uris when they differ
- `0ab4b7f` — Step 07: skip gracefully when no provider configs exist
- `866eb04` — Idempotency + safe password escaping in steps 01 and 06
