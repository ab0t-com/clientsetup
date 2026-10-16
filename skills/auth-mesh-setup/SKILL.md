---
name: auth-mesh-setup
description: >-
  Put a service on the ab0t auth mesh with the authsetup CLI, end to end, and choose the right shape
  for it. Use when a team wants sign-in, permissions and keys for its product: install authsetup, pick
  an environment, write config/permissions.json (init --publish), choose flat vs workspace-per-user,
  preview and apply with up, wire the service key and client id into the app (settings, snippet login),
  brand the hosted login page, connect to other services or open its own API to them, and verify the
  result. A short guide that routes to the numbered Ally SOPs (02–06 for day one) for every procedure.
---

# Put your service on the auth mesh

## What this is

`authsetup` gives your product sign-in for its customers, a permission model, a branded login page and
keys for your backend, all from a few JSON files you keep in your repo. You describe what you want in
`config/`, preview, say yes, and the mesh is reconciled to it; every command is safe to re-run, so
changing things later is the same loop.

## The picture

```
config/permissions.json ─┐                          invoicer                ← your app: admin + service key   (step 01)
config/oauth-client.json ├─► authsetup up ──► auth ─┤ ├── invoicer-users    ← your users + Default Users team (step 04)
config/hosted-login.json ┘   (plan → yes → apply)   │ └── invoicer-api-consumers ← your partners, optional    (step 08)
                                                    └ credentials → ~/.authmesh/invoicer/<thing>.<env>.json (0600)
```

| your product looks like… | `end_users.org_structure.pattern` |
|---|---|
| a shared tool, a dashboard, an API anyone calls, users that are bots or services | `flat` (default) |
| each customer has their own projects, invites teammates, pays their own bill | `workspace-per-user` |
| you sell to companies, each a tenant | `workspace-per-user` today |

Decide before real users arrive: switching later only gives **new** sign-ups a workspace (SOP 09).

## Do this (the default path, day one)

```sh
curl -fsSL https://raw.githubusercontent.com/ab0t-com/clientsetup/main/install.sh | sh
authsetup version                                  # these pages match 0.5.24; older → authsetup update
authsetup use-env dev                              # build on dev; prod is the default otherwise
authsetup init --publish                           # a few questions → config/ written and validated
authsetup --env dev --config-dir ./config up --dry-run   # the plan in plain words; nothing changes
authsetup --env dev --config-dir ./config up             # same plan → your yes → apply
authsetup --env dev settings --env-file .env       # backend + frontend values into .env (key never printed)
authsetup --env dev snippet login > login.html     # a working sign-in block with your real client id
authsetup --env dev login-url --check              # your customers' login page, checked
```
Then wire the backend (Python `ab0t_auth` or Go `auth-sdk-go`, always with your audience) and the
frontend (SOP 06). Prod later: the same files with `--env prod`, run in your own terminal (it asks you
to type `prod` the first time). Never copy credential files between environments.

Things that are fixed once created: `service.id`, `registration.service` and `service.audience`
(lowercase letters, digits, `_`; no hyphens). Pick the short name carefully (SOP 04).

## What your customers notice

- A login page at `https://auth.service.ab0t.com/login/invoicer-users` with your branding (SOP 07);
  sign-up through it puts them in your users org with every `default_grant` permission.
- Your API answers `401` without a valid token, `403` without the permission, `503` if the auth
  service could not be asked. A change to defaults reaches them within about five minutes or on a fresh
  login; revocations within 15 s (permissions) / 60 s (API keys) with the SDK's default caching.
- They never see ab0t or each other's data, as long as your routes check the resource's `org_id`.

## Common mistakes (and what you will see)

| mistake | what you see | fix |
|---|---|---|
| a hyphen in the service name | `registration.service "my-invoicer" will be REJECTED by the auth service registry (…). Try "myinvoicer".` | use the suggested name |
| the name belongs to someone else | `permission schema name "invoicer" is taken — it is registered to another organization (org <id>), …` | another name (nothing was created) |
| no default permission | `no permission has default_grant:true — new users would have no access` | mark the everyday read permission |
| a changing command with no `--env` | `refusing to mutate PRODUCTION (…) without an explicit target — pass --env dev …` | add `--env dev` |
| backend audience ≠ your service | `401 Audience doesn't match`, users stuck in a login loop | `AB0T_AUTH_AUDIENCE=invoicer` / `WithExpectedJWTAudience("invoicer")` |
| frontend redirect not registered | `invalid redirect_uri` | add it byte-for-byte to `oauth-client.json`, `up` |

## Check it worked

```sh
authsetup --env dev doctor                         # read-only checklist; --strict also proves the admin can sign in
authsetup --env dev --config-dir ./config status   # exit 0 converged, 3 drift
authsetup --env dev --config-dir ./config run 06   # a throwaway user signs up, gets the defaults, is removed
```
Still stuck: send `authsetup --env dev doctor --json`, `status --json`, the failing output and the
latest `~/.authmesh/<service>/journal/*.jsonl` (redacted) to `platform-team@ab0t.com`. Never delete
`~/.authmesh/<service>/` (it holds every environment, prod included) and never send a credentials file.

## SOPs (in `authmesh/`)

| job | SOP |
|---|---|
| the whole first day, end to end | [02](../../02_sop_system_day_zero_new_customer.md) |
| install, environments, who the tool acts as | [03](../../03_sop_system_install_sign_in_environments.md) |
| `permissions.json`: permissions, defaults, `scope`, roles, user shape | [04](../../04_sop_system_describe_your_service.md) |
| preview and apply; what steps 01–08 create; credential files | [05](../../05_sop_system_check_and_first_run.md) |
| wire it into the backend and frontend | [06](../../06_sop_system_wire_it_into_your_app.md) |
| login page and branding | [07](../../07_sop_system_hosted_login_and_branding.md) |
| your users; consuming other services; opening yours | [09](../../09_sop_system_your_users.md) · [11](../../11_sop_system_using_other_services.md) · [12](../../12_sop_system_opening_your_service_to_others.md) |
| changing things later; troubleshooting; security | [13](../../13_sop_system_changing_things_safely.md) · [16](../../16_sop_system_troubleshooting_and_recovery.md) · [17](../../17_sop_system_security_rules.md) |

Companion skills: `authsetup-cli` (every flag), `hosted-login-setup`, `mesh-tenancy-authority`,
`mesh-consumer-account-sop`.
