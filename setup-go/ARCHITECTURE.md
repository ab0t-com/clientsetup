# setup-go Architecture & Conventions

**Status:** v0.1.0 (2026-06-10) · **Audience:** maintainers of this tool.
**Context:** this rewrite hardens the lessons of the bash kit and of auth
ticket `20260609_llm_gateway_permission_propagation` into structure. Read that
ticket's `ROADMAP_20260610.md` for where the *platform* is going; this tool is
the client-side half of "drop-in auth."

## 1. Design principles (each traces to a real incident)

| # | Principle | Incident it encodes |
|---|---|---|
| P1 | **Reconcile, not skip.** Steps compute desired state from config, read actual state from the server, converge. "Already exists, skipping" is banned. | stale `redirect_uris` (kit commit `f108e7d`); stale team permissions (the entire 20260609 propagation ticket) |
| P2 | **Validation gates.** An invalid config never reaches the server. The validator enforces *server-side* rules too (e.g. registry service-name regex `^[a-z][a-z0-9_]*$`). | bash validator existed but didn't gate; integration's config shipped while failing validation |
| P3 | **Verify cached state.** Credentials on disk are claims, not facts — step 01 logs in and GETs the org before trusting them. | kit commit `866eb04` |
| P4 | **Surface error bodies.** Every non-2xx error carries the server's `detail`. No output suppression. | ~70 `2>/dev/null`/`\|\| true` sites in the bash kit |
| P5 | **Dry-run shows a real plan.** Reads run normally; writes route through `Context.Apply`, which prints `would: …`. The plan reflects live server state, not intentions. | bash `DRY_RUN=1` printed intended calls without diffing |
| P6 | **One run at a time.** Lockfile in the credentials dir. | "no concurrency lock" (SUGGESTIONS.md) |
| P7 | **Run summary + NEXT block.** Every command ends with a per-step table and a NEXT block (house convention, commit `9d21ed9b` in the auth repo). | `set -e` stopped bash runs with no report |
| P8 | **Zero external dependencies.** Stdlib only: auditable, no supply chain, builds offline, single static binary. | — |
| P9 | **Never fabricate endpoints.** Every API method maps to a call the bash kit makes or one verified against the live OpenAPI. Flows whose shapes weren't re-verified (07/08) are explicit non-ported stubs, not guesses. | house rule (auth CLAUDE.md) |
| P10 | **Credentials: 0600, gitignored, merge-preserving saves, bash-compatible shapes.** | setup/ leak history; toolchain interop during migration |

## 2. Package layout

```
setup-go/
├── cmd/authsetup/main.go      CLI: flag parsing, command dispatch, NEXT blocks
├── internal/
│   ├── api/client.go          typed HTTP client: retries, error model, all endpoints
│   ├── config/config.go       typed config structs + loader + GATING validator
│   ├── creds/store.go         credentials store: env suffix, 0600, deep-merge saves
│   ├── steps/
│   │   ├── runner.go          Step interface, Context.Apply (dry-run), lock, summary
│   │   ├── s01_s04.go         provisioning steps (service org → end-users org)
│   │   └── s05_s09.go         verify, e2e test, consumer stubs, backfill
│   └── ui/ui.go               colored output, NEXT helper (TTY/NO_COLOR aware)
├── docs/MIGRATION.md          bash → Go mapping, gaps, parity notes
├── Makefile                   build/check; artifacts are built manually (house rule)
└── README.md                  operator-facing usage
```

Dependency direction: `cmd → steps → {api, config, creds, ui}`. `api` knows
nothing about config or steps. Nothing imports `cmd`.

## 3. The step contract

```go
type Step interface {
    ID() string    // "01".."09" — stable, used on the CLI
    Name() string
    Run(*Context) error
}
```

Rules for writing a step:
1. **Idempotent + reconciling** (P1). Read first. Only mutate the delta.
2. **All mutations through `Context.Apply(desc, fn)`** — this is what makes
   dry-run trustworthy. A write that bypasses `Apply` is a review-blocking bug.
3. **Permission arrays converge by additive union** (`union`, `missing`
   helpers). Removal is an explicit operator action, never an implicit sync.
4. **Steps own their credential files** and read others' via `creds.Store`
   only. Shapes stay bash-compatible (see `creds` package).
5. **No step talks to stdout directly except via `ui`.**

## 4. Error model

`api.Error{Status, Detail, Body}` for any non-2xx; helpers (`api.IsStatus`)
for branching (e.g. 404 → create). Retries: 3 attempts, linear backoff, on
network errors and 502/503/504 only — every endpoint we mutate is server-side
idempotent (PUT-replace or create-with-conflict), so retry is safe. 4xx never
retries: it's a real answer.

## 5. Security conventions

- Passwords: `crypto/rand`, 22+ chars, mixed classes, `@` not `!` (shell
  history-expansion trap documented in the billing setup).
- Credentials written 0600; directory expected gitignored (the repo's
  pre-push hook also guards this).
- Tokens live only in memory (`api.Client.Token`); never logged, never in
  `Changed` descriptions.
- The RFC 7592 `registration_access_token` is persisted (0600) because losing
  it makes the OAuth client permanently unmanageable; re-persisted on every
  update because the RFC allows rotation.
- No dynamic strings into anything user-facing on the server side — this tool
  only ever sends operator-authored config values.

## 6. Known platform couplings (will change under the auth roadmap)

- **Backfill exists because policy is materialized.** When the auth service
  ships live org-type policy (ticket roadmap Tier 2), `backfill` and step 04's
  team-permission sync become migration-era artifacts — delete them then.
- **Workspace detection by team-name presence**, not org settings: the
  admin-side hierarchy hides `settings` (auth ticket 20260402 Task 41).
- **Cross-org authority caveat:** backfill PUTs teams in child workspace orgs
  the admin is not a member of. Whether `teams.write` resolves for a
  parent-org admin there is environment-dependent (see the 20260609 ticket's
  PR review, T11 watch-item) — `backfill --only-org` against one workspace is
  the mandated first run.
- **Custom roles don't resolve server-side yet** (`roles[]` is used for the
  default-role id and validation only). When the auth service ships role
  upload (CR-1/CR-2), step 01 grows a "publish roles" action.

## 7. Testing strategy

- `make check` = `go vet` + `gofmt -l` + build. CI should add `go test ./...`.
- Unit targets: `config.Validate` (table-driven), `creds.deepMerge`,
  `steps.union/missing`, `api.newError`.
- Integration: run against a local auth stack (`make up` in the auth repo),
  then `authsetup --base-url http://localhost:8001 --dry-run run` must
  produce a plan with zero errors; `run` then `run 05` must pass; `run 06`
  proves the end-user journey. The auth repo's UJ-316 covers the server-side
  seeding regression this tool's backfill complements.

## 8. Versioning & release

Semver in `cmd/authsetup/main.go`. Build artifacts are produced manually via
`make build` and committed/released deliberately — no auto-building in
Dockerfiles or CI image steps (house rule). Cross-compile targets can be added
to the Makefile as needed (`GOOS=linux GOARCH=arm64 make build`).
