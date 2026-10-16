# Migration: authsetup v0.5.23 → v0.5.24

**Who is affected:** almost nobody needs to change anything — re-run as normal. You are affected only if a script, CI
job or agent (a) matches authsetup's human output text (schema lines, ownership errors, run summaries, NEXT lines —
much of it is reworded in this release), (b) matches the auth service's ownership refusal text exactly, or (c) worked
around the invalid `providers --json` / `update --json` output (R12). No default step set changed and no existing
`--json` key was removed; the exit-code changes apply only to a config that could never apply (R6) and to an auth
server that points authsetup at another origin (R18 — a security fix: credentials are no longer sent there). Run the
checker: `./migrate-check.sh /path/to/your/repo`.

Each row says what changed, whether it can break a script and why, and what a script or agent should do.

## R1 — the permission schema is registered only by your service org
| Before (v0.5.23) | After (v0.5.24) |
|---|---|
| Steps `04` (end users) and `08` (API consumers) re-registered the schema while signed in as the end-users / consumers org | Only your **service org** ever registers it (the owner). Step `01` registers it; steps `04` and `08` check it as the service org — nothing to do when it is current, a re-register as the service org when it is missing or out of date |

*Why:* the auth service lets only a schema's owner change it. The re-register from the end-users or consumers org was
refused (`403`) and could stop step `04` before it updated your sign-in client.
*Breaking?* No — fewer calls, same exit codes.
*Migration:* nothing to change. If you were stuck at step `04`/`08` with a 403 on the schema: upgrade and re-run.

## R2 — schema output lines name the org (wording changed)
| Before | After |
|---|---|
| `register permission schema on end-users org` | `register permission schema for "<service>" as service org <id> — admin surface` |
| (no line when current) | `permission schema "<service>" already registered and owned by service org <id> — admin surface — nothing to do` |
| — | `permission schema "<service>" already registered (no owner recorded in the registry yet) — nothing to register from here` |

On a **first** run (no service org yet) the dry-run plan line is still `register permission schema for "<service>" (N
actions, M resources)` — there is no org id to name until step `01` creates the service org.
*Why:* say which org each call acts as, so people and agents can see what happens.
*Breaking?* Only for scripts that match the old line text.
*Migration:* there is **no machine-readable equivalent yet** (`info --json` lists which config file drives which
object; it does not report what a run did). Branch on the **exit code** (`0` converged, `1` failed) and, if you must,
on the presence of `nothing to do` — never on the exact line.

## R3 — ownership refusals carry a code and the owner (auth-service response)
| Before | After |
|---|---|
| `403 {"detail":"…only its owner or a platform admin can change it"}` | `403 {"detail":"…only its owner or a platform admin can change it — register as the owner org or ask a platform admin","error_code":"REGISTRY_NOT_OWNER","owner_org_id":"<id>"\|"platform"\|null}` |

*This is a server-side change and depends on the auth-service release*, not on this binary. authsetup 0.5.24 reads
`owner_org_id` when it is present to tell the R5 cases apart; against an older auth service it says it could not tell.
*Breaking?* Only for code that matches the detail text exactly (it gained a suffix).
*Migration:* match `error_code == "REGISTRY_NOT_OWNER"` and read `owner_org_id`, never the detail text.

## R4 — no per-org schema copy for the end-users / consumers orgs
*Before:* the old re-register also wrote a per-org copy of the schema entry under the end-users and consumers orgs.
*After:* only the service org's entry is written. Nothing in the auth service relies on those copies for your service.
*Breaking?* No. *Migration:* none, unless you read those entries directly (you should not).

## R5 — ownership failures are explained by authsetup (text changed)
| Case | v0.5.23 said | v0.5.24 says |
|---|---|---|
| another organization owns the name | `HTTP 403: … owned by another organization …` | `permission schema name "<service>" is taken — it is registered to another organization (org <id>), not to your service org <slug> (<id>).` + choose a different `registration.service`, or `--creds-dir` the setup that owns it |
| the name is reserved by the platform | (same 403 text) | `permission schema name "<service>" is taken — it is reserved by the auth platform …` + choose a different `registration.service` |
| registered with **no owner recorded** (old entry) | (same 403 text) | `permission schema "<service>" is registered with no owner recorded …` + ask the auth team to record your service org as its owner; re-running will not help |
| the server did not say which (older auth service) | (same 403 text) | `the auth service refused to register permission schema "<service>" for your service org …: either another organization owns that name, or it has no owner recorded` + both fixes |

The message is produced by authsetup, so it **no longer contains `HTTP 403`**, the phrase `owned by another
organization`, `set_schema_owner`, or advice to re-run `authsetup run 01` (re-running cannot fix any of these cases).
*Breaking?* **Yes, for text-matching scripts** — a script that greps `HTTP 403` or `owned by another organization` to
detect this failure silently stops matching. The exit code is unchanged (`1`).
*Migration:* treat **exit code `1`** as the only stable signal; to tell the cases apart, match `is taken` / `no owner
recorded`, and treat anything else as "needs a human".

## R6 — step 01 checks the schema name before it creates anything
*Before:* a first `--dry-run run` (or `up --dry-run`) approved a schema name another organization owns; the real run
then created your admin account and service org and failed at the end of step `01`, leaving them behind.
*After:* step `01` reads the public registry first — in a dry run too. A name owned by another organization (or
registered with no owner, when your config would change it) stops step `01` with the R5 message **before anything is
created**. A registry that cannot be read is "unknown" — authsetup says so and goes on, and checks again once your
service org exists — never "taken".
*Breaking?* Only for a config that could never apply: its first `--dry-run run` / `up --dry-run` now exits `1` instead
of `0`. Working setups are unaffected.
*Migration:* none. A non-zero dry run now means the apply would fail — fix the name it reports.

## R7 — step 04 checks the schema last
*Before (0.5.24 pre-release):* if the schema check failed in step `04`, the step stopped before it updated the
end-users sign-in settings and client.
*After:* step `04` brings the end-users org, default team, sign-in settings and end-users OAuth client up to date
first, saves them, and checks the schema last. If the check fails the step still fails (exit `1`) and names the schema.
Step `08` keeps checking first: publishing tiers for a schema you do not own would advertise permissions you cannot
grant.
*Breaking?* No — same exit code; more of the step is applied.
*Migration:* none.

## R8 — NEXT lines carry the target you used
*Before:* many NEXT lines dropped the target — after `authsetup --env local --dry-run run` the suggested
`authsetup run` resolved to **production**; `validate` suggested `authsetup --dry-run run` (a dry run against
production); `connect --dry-run` dropped `--as`; NEXT lines built as `--env <label>` broke when the label was derived
from a URL.
*After:* every NEXT command carries how the target was chosen: `--env <name>`, or `--base-url <url>` when the
environment was derived from a URL (a derived label such as `localhost` is not a valid `--env`), plus `--config-dir`
when you passed one and `--as` for connect/disconnect. When nothing chose the target, the flag is left out on purpose
(the production guard still sees an un-chosen target). `validate` points at `--env dev`. After a full `run`, NEXT
points at `status`, `settings` and `login-url` instead of re-running `05`/`06`. After `destroy`, NEXT says to move the
credentials directory aside instead of `rm -r`.
*Breaking?* No — NEXT is advice text; no exit code or JSON changes.
*Migration:* none. Agents that copy NEXT lines now reach the same environment they started on.

## R9 — step 06 removes its throwaway test user
*Before:* every `run` / `up` registered a new `setup-go-test-…@test-uj.example.com` user in your end-users org (in
production too) and nothing removed it.
*After:* step `06` still registers a user and checks it receives your default permissions, then the user deletes its
own account (pass or fail). A failure to remove it is a warning naming the account, never a step failure.
*Breaking?* No — same checks, same exit codes. `destroy` lists fewer members.
*Migration:* none. To clean up users left by older versions, remove `setup-go-test-…` members from your end-users org.

## R10 — run summaries say what really happened (wording)
| Before | After |
|---|---|
| a re-sent setting printed `✓ PUT login-config on …` like a change | `~ re-sent: PUT login-config on …  (authsetup cannot compare this setting, so it sends it again — same values)` |
| a converged re-run never said so (re-sends counted as changes) | `no changes were needed — server state already matches config (N setting(s) re-sent …)`; with real changes: `N changed · M re-sent` |
| `N step(s) not reached` | one line per step: `NN  <step name>  not reached` |
| last line `✗ run failed` | `✗ run failed at step NN (<step name>)`; NEXT prints the exact resume command (`run NN …`) with your `--env` |
| dry run: `→ would: deferred — needs output of an earlier step's apply (<OS error>)`, ✗ lines from step 05, a planned count lower than the would-lines | `· deferred — it needs your service org, which step 01 creates; …` (an info line, not a would-line); no ✗ in a dry run; the count equals the would-lines (the first-run schema register and step 08's directory publish are now counted) |
| `status` printed `── Run summary ──` / `no changes were needed` | `── Check summary ──` / `checked — server state matches config` (`status --pipeline` is unchanged) |
| a cannot-repair step showed `ok` | `needs you`, plus the redirect-URI difference (`+`/`-`) and three concrete options, restoring the credentials file first |

*Breaking?* No exit code or JSON changes. Scripts that grep these lines (`✓ PUT`, `step(s) not reached`,
`would: deferred`, `Run summary` from `status`) stop matching.
*Migration:* use the exit code (`0`/`1`/`4`); do not parse the summary.

## R11 — errors explain themselves (wording)
- Saved admin credentials that no longer sign in: was `cached credentials no longer valid against <url>: HTTP 401: …`;
  now names the file, the admin email and three likely causes (data reset → move the file aside; wrong env/creds
  dir → `authsetup info`; password changed → update `admin.password`). Exit `1` as before.
- OAuth-shaped server errors read as prose: `HTTP 400: invalid_redirect_uri — Invalid redirect URI: notaurl` (was the
  raw JSON body); a refused OAuth client also names `<config-dir>/oauth-client.json`.
- Lock held: was `another run holds <path> (pid N) — remove the file if that run is dead` after a NEXT block; now
  only the error, and it says whether that run is alive (`… is working on this setup right now — wait`) or stale
  (`… it is safe to remove that file`).
- Invalid JSON in a config file: was `permissions.json is required: <path>: invalid character …`; now
  `<path>: invalid JSON at line L, column C — …`. (`permissions.json is required: …` still means "missing".)

*Breaking?* Text only; exit codes unchanged. *Migration:* none — branch on the exit code.

## R12 — machine-readable output is one document; a typo'd flag is one line
- `providers --json`: stdout is now exactly one JSON document (the `· env:` line before it and the NEXT block after
  it are gone). A script that worked around the invalid output by stripping lines (`tail -n +2`, `sed`) must drop the
  workaround — it would now cut real JSON.
- `update --json` on a failure prints `{"action":"error","current":"…","error":"…"}` (exit `1`) instead of a human `✗` line.
- `validate --json` when a config file cannot be read prints the usual document with `valid:false` and the reason in
  `problems[]` (exit `1`) instead of a human line; every `validate --json` document gains an additive `warnings` array.
- An unknown flag prints one line — `unknown flag --jsn — did you mean --json?  (see \`authsetup providers --help\`)` —
  on stderr, instead of the error plus the whole 200-line help screen. Exit code stays `2`.

*Breaking?* Only for scripts that relied on the old invalid `providers --json` / `update --json` output.
*Migration:* parse the JSON directly; read `warnings` if you want the non-gating advisories.

## R13 — validate is clearer (wording; no new gating rule)
- A `registration.service` the registry refuses is ONE problem line that suggests the same id `init --publish` would
  generate (`UXRevTest` → `uxrevtest`, `my-svc` → `mysvc`) and counts the permission ids to rename — instead of one more
  line per permission id.
- New non-gating warnings: a redirect URI the auth service will refuse (no scheme/host, or a `#fragment`), and an
  `oauth-client.json` that exists but is not valid JSON (it used to be silently treated as missing, which skipped the
  OAuth client steps). Warnings never change the exit code.
- `validate` / `init --publish` say the printed auth URL was not contacted (`… — not contacted: validate is local-only`).

*Breaking?* No — the problem COUNT can drop (1 instead of 1+N) for a bad `registration.service`; validity and exit
codes are unchanged. *Migration:* none.

## R14 — who acts where, and where files are
- At each switch of identity or org, the run prints `· acting as <admin email> in your service org <slug> (<id>)` (or
  `your end-users org …` / `your consumers org …`).
- `saved credentials/<svc>.<env>.json (0600)` (a relative path that did not exist) → the real absolute path.
- No config found: the error comes first, then a NEXT with `authsetup init --publish` and `--config-dir`.

*Breaking?* No. *Migration:* none.

## R15 — consumers and the mesh directory say the truth
- Step 08 with self-serve sign-up off (the default) no longer prints `consumers self-register with: POST …`; it says
  sign-up is off and how to open it (`registration.signup_enabled: true` in `api-consumers.json`); the publish line
  says `listed but closed`.
- `providers` lists a closed provider as `closed — invitation only` (was `signup DISABLED`), the header counts open vs
  closed (was `N mesh provider(s) accept self-serve consumers` counting closed ones too), and a closed provider gets
  no `connect` line.
- The derived "Standard Consumers" tier description says what it carries ("Your default permissions …"), not
  "Read + write access" (new teams only; existing team descriptions are not rewritten).
- `connect` off production no longer prints a guessed production URL: `<SVC>_SERVICE_URL=` is left empty with a
  comment line "not published for this environment — ask the provider for its URL". Production is unchanged.

*Breaking?* Text only — except a script that copies `<SVC>_SERVICE_URL=` from `connect` output on a non-production
environment now gets an empty value (the old value paired a non-production key with the production host).
*Migration:* off production, set the provider's URL from the provider.

## R16 — `</dev/null` is not a terminal
Commands that ask (`destroy`, the production confirm, the gitignore consent, `disconnect`, `init`) treated stdin
`/dev/null` (common in CI) as a terminal: they printed the question, read nothing, and failed with the interactive
message. They now give the non-interactive refusal straight away (`pass --yes`, `AUTHSETUP_CONFIRM_PROD=1`,
`--write-gitignore`). *Breaking?* No — the same exit code `1`; only the message differs. *Migration:* none.

## R17 — doctor, help and docs
- `doctor` has a new, NON-GATING row: `admin sign-in`. By default it only reads the saved admin credentials file; with
  `--strict` it also signs in once and warns when they no longer work (see R19). `doctor --json` gains that entry in
  `checks[]` (additive); the exit code is unchanged.
- `doctor`'s NEXT is an action ("could not check GitHub for updates" is no longer offered as a next step); paths in
  its table are printed in full (no `…`).
- `--help`: the exit-code table now matches the binary (`2` = unknown flag; an unknown command or step is `1`), and
  the agent-skill pointer is `authsetup skills install` (the `llms.txt` it cited did not exist).
- The bundled agent skill (`authsetup skills`), README and docs/USAGE.md are refreshed around `init --publish` → `up`.

*Breaking?* No. *Migration:* none.

## R18 — credentials go only to the auth URL you gave (security)
*Before:* authsetup followed URLs the auth server handed it, wherever they pointed: the RFC 7592 client-management URI
(`registration_client_uri`, used by steps `02`/`04` to update a sign-in client's redirect URIs and by `obo-actor`
rotate/disable to revoke a client) received the client's registration access token even when it was on another host;
and an HTTP redirect was followed to another origin — Go keeps the `Authorization` header on a redirect to the same
host over another scheme or port (or to a subdomain), and re-sends a `307`/`308` request body, which can carry a
password, to any host. An auth server with a mis-set public URL (for example a local server that still advertises the
production host) therefore made authsetup send a local credential to production.
*After:* authsetup sends a request — and so any credential — only to the same scheme + host + port as the auth URL it
is using (`--env` / `--base-url`). A management URI on another origin is not contacted: the step fails with
`the auth server at <your auth URL> advertises its client-management endpoint on <other origin> — a different origin,
so authsetup sent nothing there …; check that auth server's BASE_URL (or its proxy) setting`. A redirect to another
origin is not followed: `the auth server at <origin> redirected <METHOD /path> to <other origin> — …`. Same-origin
redirects are still followed.
*Breaking?* **Yes, for one narrow case — on purpose.** A setup whose auth URL differs in origin from what its auth
server advertises (an alias host, `http://` vs `https://`, a non-default port, a proxy that redirects elsewhere) used to
"work" by sending credentials to that other origin; it now fails the step with exit `1` (the existing step-failure exit
code; for `obo-actor` rotate the old client's revoke becomes a "needs you" item). Every setup whose server advertises
its own URL is unaffected.
*Migration:* if you see the message, fix the auth server's public URL setting (its `BASE_URL`) — or, if the advertised
origin is the right one, use it as your `--base-url` — then re-run. To check a server up front:
`curl -s <auth URL>/.well-known/oauth-authorization-server | jq -r .registration_endpoint` must start with your auth URL.

## R19 — `doctor` does not sign in unless you ask (`--strict`)
*Before (0.5.24 pre-release only):* every `doctor` run signed in with the saved admin credentials. With stale
credentials each run was a failed login that counts toward the admin account's lockout — and `doctor` is often run
as a frequent readiness probe.
*After:* by default the `admin sign-in` row only reads the saved credentials file (present and readable → `✓ saved
credentials present (sign-in not tried) — run \`authsetup … doctor --strict\` to verify the admin can sign in`;
unreadable → `◐`). Nothing is sent. `doctor --strict` also signs in once and reports stale credentials as `◐` (still
non-gating — `--strict` keeps gating only the service-key capability gap).
*Breaking?* No — v0.5.23 had no admin row at all, the row stays non-gating, and exit codes are unchanged.
*Migration:* none. Run `authsetup --env <env> doctor --strict` when you want the sign-in verified.

## Verify
1. `authsetup --version` prints `authsetup 0.5.24`.
2. On an existing setup: `authsetup --env <env> --dry-run run 01 04` — every schema line names your service org or
   says `nothing to do`.
3. On a first setup: `authsetup --env <env> --dry-run run 01` either plans `register service admin`, `create service
   org` and `register permission schema …`, or stops with the R5 message if the name is taken.
4. `./migrate-check.sh /path/to/your/repo` reports no findings.

## Rollback
Reinstall the v0.5.23 release binary. No data migration is involved; the changes are client-side behaviour only.
