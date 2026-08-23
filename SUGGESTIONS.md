# Suggestions

A living list of robustness, idempotency, ergonomic, and feature
improvements for the setup CLI. Open items are bugs we know about but
haven't shipped fixes for; closed items move to the changelog (or just
get deleted from this file when the PR lands).

## How to add a suggestion

You don't need to be a maintainer. Three ways, in increasing order of
weight:

1. **Open a GitHub issue** at
   https://github.com/ab0t-com/clientsetup/issues with a
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

## Open: correctness gaps

- **P0 — `service.audience` is parsed and never sent, and the resulting
  default is IRREVERSIBLE.** Every service's `permissions.json` declares
  `service.audience`; the Go loader binds it at
  `setup-go/internal/config/config.go:32` and **nothing reads it** —
  `grep -rn 'service_audience\|ServiceAudience' setup-go --include='*.go'`
  and `grep -rn '\.Audience' setup-go --include='*.go'` are both empty, and
  `CreateOrgRequest` (`setup-go/internal/api/client.go:338-345`) has no such
  field, so step 01 (`internal/steps/s01_s04.go:127-131`) creates the service
  org without it. The auth server then falls back to `LOCAL:{org_id}` silently
  (`auth/output/appv2/services/organization/org_service.py:88-105`) — and that
  field is **immutable after creation**
  (`models/organization.py:120`, `org_service.py:349-351`), so no re-run of any
  step can ever repair it and there is no API that can. **The retired bash kit
  DID send it** (`scripts/01-register-service-permissions.sh:184-192`) — this is
  a regression introduced by the Go rewrite. Live effect: four mesh service org
  trees (`audit`, `resource`, `banking`, `schema-service`) mint
  `aud: ["LOCAL:{uuid}"]` while their services enforce a service-name audience;
  audit's entire customer base is locked out by it. Sketch of the fix:
  (a) add `ServiceAudience string \`json:"service_audience,omitempty"\`` to
  `CreateOrgRequest` and pass `p.Service.Audience` in step 01;
  (b) decode it on `Org` (`client.go:330-336`) so the CLI can read back what the
  server stored;
  (c) **fail the run** when `service.audience` is absent or malformed, and when
  an org adopted by slug (`s01_s04.go:118-124`) carries a *different* audience —
  that one check would have surfaced all four broken services on their next run;
  (d) write `service_audience` back into the credential file, which
  `scripts/validate-config.sh:537-540` and
  `intergration/output/setup/schema/credentials-service.schema.json:14` both
  still expect and the bash kit used to produce.
  **Note the trap:** the auth server's slug→audience auto-derivation is *not* a
  substitute. It derives from the org slug (= `service.id`), and `service.id` ≠
  `service.audience` for `resource`/`resource-service`,
  `banking`/`banking-service`, `billing`/`billing-service`,
  `payment`/`payment-service` — so for those four it produces the **wrong**
  audience, not the declared one.
  Full investigation, evidence and remediation plan:
  `auth/output/tickets/20260823_service_audience_never_set_by_setup/`
  (one-command reproduction: `scan_service_audience.sh` in that directory).

- **`scripts/__backfill-service-audience.sh` is a foot-gun, not a repair tool.**
  It is the only mechanism anywhere that can change `service_audience` on an
  existing org, and it hardcodes `SERVICE_AUDIENCE="integration-service"`
  (`:22`) plus dev/prod org ids (`:29-35`) and writes DynamoDB with an
  unconditional `SET` (`:63-68`). Pointed at any other service's org it silently
  stamps `integration-service` on it. It is `__`-prefixed (out of the runnable
  set) but discoverable, and it *looks* like the answer to the bug above.
  Suggest: archive it with a header pointing at the supported route, or strip the
  hardcoded audience and org ids so it cannot run unparameterised. Ideally the
  capability moves server-side (a privileged, audited, null→value-only setter) —
  a client-side setup tool holding production datastore credentials is the wrong
  shape.

- **Two more `permissions.json` keys are parsed-or-declared and never read.**
  `roles[].permissions` — `DefaultGrantIDs` (`internal/config/config.go:96-105`)
  builds the default team from `permissions[].default_grant`, and `DefaultRole`
  (`:109-121`) reads a role only for its **id**, so a role's permission list
  grants nothing (this already caused one wrong root-cause diagnosis on the audit
  service). And `multi_tenancy` — declared by all nine in-tree services, with
  `"enforcement": "strict"` and a `cross_tenant_permission`, and
  `grep -rn 'multi_tenancy\|MultiTenancy' setup-go --include='*.go'` is **empty**.
  Suggest the general antidote: **a top-level config key that no code path reads
  must fail `validate-config.sh`.** A config file that a tool reads only part of
  gives readers no way to tell configuration from documentation.

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
