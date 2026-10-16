# Migration: authsetup v0.5.26 → v0.5.27

**Breaking: none for normal use. One behaviour change a script can notice (R1): where 0.5.26 STOPPED on a revoked service
key, 0.5.27 MINTS a new one.** Everything else is wording, an additive `--json`, and one exit code for a case that was
mislabelled. Run `authsetup update`, then `./migrate-check.sh /path/to/your/repo` (read-only). Most repositories get
`No v0.5.27 migration findings.`

## R1 — a revoked service key is re-minted by `run` / `up` (behaviour change)
| Before (v0.5.26) | After (v0.5.27) |
|---|---|
| The saved service key failed validation (`valid:false`: revoked or deleted on the server). Step 01 printed `✓ service API key already provisioned (id …)`, then `✗ step 01 failed: service API key … failed validation: …` / `→ fix: re-mint (rotate the key; run step 01 on fresh creds)`, exit `1`, and a NEXT that repeated the command that had just failed. The only fix was by hand (SOP 14: empty `api_key` in the creds file, `run 01`). | Step 01 prints `· a service API key is saved (id …) — checking it still works`. On a definite `valid:false` it moves the dead key's entry to `<creds>/.archive/<svc>.<env>.api_key.<id>.<ts>.json` (0600, never deleted), mints a new key `<svc>-internal` with every declared permission, saves it, and prints `your saved service key no longer works (revoked or deleted) — minted <new id>; deploy it: authsetup --env <env> [--config-dir <dir>] settings --env-file .env, then restart your app (it still holds the dead key)`; its NEXT leads with that settings line and "then restart your app". The run continues and exits `0`. `--dry-run run` / `up --dry-run` show `re-mint service key (saved key is revoked) — new key "<svc>-internal" with N permission(s)` and change nothing. |
| A 5xx / timeout / unreachable auth service during the check: `validate service API key against <url>: …`, exit `1`. | Same stop (exit `1`), nothing minted, clearer words: `could not check the saved service API key <id> against <url> (…) — a failed check is not a revoked key, so nothing was re-minted; retry when the auth service answers`. |

*Breaking?* It is a behaviour change: **the tool now creates a credential where it used to stop.** It only happens when
the auth service has said, with a `200`, that the saved key is not valid, so there was no working key to keep. The old key
is not revoked by authsetup (the server already refuses it); its entry is kept in `.archive/`.
*What to check:*
1. A pipeline that ran `authsetup run` and **expected** it to fail on a dead key (to page someone) now succeeds. Watch
   for the line `your saved service key no longer works (revoked or deleted) — minted` or, with `--json`,
   `service_key.reminted`, and page on that instead.
2. After a re-mint, **deploy the new key**: `authsetup --env <env> settings --env-file .env`, then restart the backend.
   Until then the backend still holds the dead key. (`status` cannot see your app: its "nothing to change" is about the mesh.)
3. Scripts that parsed the old text (`re-mint (rotate the key`, `fresh creds`, `failed validation`) never see it again.
   The checker flags them.
4. An **under-permissioned** key (valid, missing permissions) is unchanged: still a stop with the SOP 14 fix.

## R2 — `status` names a revoked key; a failed key check is exit `1`
| Before | After |
|---|---|
| `05 ⚠ drift`, NEXT `authsetup --env dev run  # reconcile the provider-pipeline drift above`, exit `3` — for a revoked key AND for a key check that could not run. | Revoked: NEXT `authsetup --env <env> [--config-dir <dir>] run   # your saved service key <id> no longer works (revoked or deleted) — run mints a new one` + `… settings --env-file .env`; exit `3` (run now reconciles it). Check could not run: `could not check your service key <id> (the auth service did not answer) — retry … status later`; exit **`1`**. `doctor` names the same with the same command. |

*Breaking?* Only for a script that treated `status` exit `3` as "re-run fixes it" **during an auth outage**: it now gets
`1`, which is the truth (a re-run cannot fix an unanswered call). `status || authsetup run` still works.
The general drift NEXT now uses the same flag echo as other commands (`--config-dir` when given; no `--env` when nothing
chose the target).

## R3 — `run --json`, `up --json`; a warning for `--json` elsewhere (additive)
| Before | After |
|---|---|
| `run --json` / `up --json` were silently ignored: human text, exit as usual. | One JSON document on **stdout**: `{schema_version:"1", command, env, service, exit_code, dry_run, steps:[{id, name, status: ok\|failed\|deferred\|needs_human\|not_reached, error?, duration_ms, actions:[{description, outcome: planned\|planned_resend\|changed\|resent}]}], cannot_repair:[], service_key?:{revoked?, reminted?, unchecked?}, error?}`; `up` adds `applied` and `planned`. Every human line (including NEXT and `✗`) goes to **stderr**. `exit_code` equals the process exit code. **`up --json` without `--yes` only plans** (exit `0`, nothing applied). |
| `--json` on `env`, `init`, `backfill`, … was silently ignored. | Same output and exit code, plus one stderr line: `! --json is not supported by "<cmd>"; the output below is human text (commands with --json: …)`. |

*Breaking?* No for anyone who did not pass `--json` to run/up. A script that passed `--json` to `run`/`up` and grepped
the text on stdout now finds JSON there (the text is on stderr). The checker flags `run`/`up` with `--json` piped to a
text tool.

## R4 — wording (no exit code changes)
| Before (0.5.26) | After (0.5.27) |
|---|---|
| `doctor`, no config: `none here — pure-consumer mode (provider setup skipped)`; NEXT the same text | `none here — consumer only (no permissions.json in this folder, …)`; NEXT `… init --publish` and `… connect <provider> --as <you>` |
| `authsetup env`: an overridden built-in reads `(built-in)` | `(override: <file>)`; a custom env `(registry: <file>)` |
| `environment "dev" resolves to <u1> but an explicit URL <u2> was also given — they must agree (drop one)` | `--env dev is <u1> (from <file>\|built-in), but --base-url <u2> was also given — they disagree. Run ONE of:` + on their own lines `authsetup --env dev <your command>   # keep the named environment; drop --base-url` and, when `<u2>` is another env, `authsetup --env <that env> <your command>` |
| `up needs a chosen environment and never guesses production — pass --env dev (or --env prod), or run `authsetup use-env dev` once` | `up needs a chosen environment and never guesses production. In a script, name it on the command:` + `authsetup --env dev … up --yes` + `AUTHSETUP_CONFIRM_PROD=1 authsetup --env prod … up --yes` + the use-env note |
| a first schema register: `~ re-sent: register permission schema … (… same values)` | `✓ register permission schema …` (and `+` in the `up` plan) — still `~ re-sent` for a drifted or unread schema |
| step 05: `scope: undeclared (auth classifies its permissions by name — add "scope" …)` | `scope: undeclared (optional — nothing to do: …)` |
| plan: `+ register service admin x-admin@example.com` | `+ register service admin x-admin@example.com (set ADMIN_EMAIL to use a real mailbox you control)` (plan only; not when `ADMIN_EMAIL` is set) |
| a taken schema name: `What you can do: choose a different registration.service in permissions.json (it names your permissions, e.g. "x_app") and run again; …` | `What you can do: choose a new name (…; e.g. "xapp") and use it in ALL FOUR places in permissions.json, which must match — service.id, service.audience, registration.service and the prefix of every permission id — then `authsetup validate` and run again; …` + numbered steps: `1. Is org <id> yours? … whois <id>` · `2. … ALL FOUR places …` with a real permission-id example, and for a starter config the one command `authsetup … init --publish --as <new> --force` · `3. … validate`, `… up --dry-run` |
| a first `PUT login-config` on an org the same run created: `~ re-sent: PUT login-config …` | `✓ PUT login-config …` (later runs still `~ re-sent`) |
| `status`, converged, 0 connections: `all connections LIVE and the pipeline is converged — nothing to do.` | `no connections; the pipeline is converged — nothing to change on the mesh.` + a WHY that `status` cannot see your app (after a re-mint: `settings --env-file .env` and restart your app) |

*Migration:* only scripts that grep these exact phrases. The checker lists them.

## R5 — NEXT lines keep your flags
`init --publish` keeps `--env`; a failed `up --yes` repeats `--config-dir` and `--yes`; `up`'s closing lines, `status` and
`doctor` carry `--config-dir` when you gave it. No action needed; a pasted NEXT line now lands where you meant.

## R6 — Ally (embedded copy) 0.5.27
`authsetup bot install` (and `--project` where you use it) refreshes SOPs 03, 14, 16 and GAPS: the revoked-key recovery,
the new messages above, and that `ab0t_sk_live_…` is every key's prefix on every environment (`live` is not production).
