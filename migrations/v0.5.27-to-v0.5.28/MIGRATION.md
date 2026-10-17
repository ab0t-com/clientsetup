# Migration: authsetup v0.5.27 → v0.5.28

**Breaking: none.** Upgrade (`authsetup update`) and carry on. The checker (`./migrate-check.sh /path/to/your/repo`)
flags a service name with `_` in your `config/permissions.json`. A NEW setup with such a name fails at step 05; a setup
that already works with one is not affected. Most repositories get `No v0.5.28 migration findings.`

## R1 — authsetup never generates a service name with `_`
| Before (v0.5.27) | After (v0.5.28) |
|---|---|
| `init --publish` turned a name with a space into one with `_` (`--as "my app"` → `my_app`), and the "name taken" message suggested names that could contain `_` | names are lowercase letters and digits only (`my app` → `myapp`); suggestions likewise |

*Why:* the auth service drops `_` from the org names it creates (`nw_rent` → org `nwrent`, users org `nwrent-users`).
authsetup then looked for the sign-in page under the name with `_`, got a 404, and step 05 failed on the first run.
*Breaking?* No. A script that called `init --publish --as "<two words>"` and then used the generated name `a_b` in a
later step gets `ab` instead. The checker can't see that; search your scripts for the name you pass to `--as`.

## R2 — `validate` warns about `_` in the service name
`validate` (and `--json` `warnings`) prints, for `service.id` or `registration.service` containing `_`:
`service name "nw_rent" contains "_" — the auth service drops it from org names (your orgs would be "nwrent" and
"nwrent-users"), so a NEW setup fails at step 05 (sign-in page not found). Use letters and digits only, e.g. "nwrent", …
A setup that already works with this name is not affected.`
*Breaking?* No: a warning, never an exit code. *Migration:* for a setup you have not created yet, rename it in all four
places (`service.id`, `service.audience`, `registration.service`, every permission prefix). For one that already works,
nothing to do.

## R3 — Ally's pages answer four first-setup questions
`authsetup bot install` refreshes Ally. SOP 04 covers choosing the service name, SOP 05 what `ADMIN_EMAIL` is for, SOP 06
whether the validate calls need your service key (no), and SOP 09 a shared users org (`flat`) or a workspace per user,
including what your backend must compare in each.
*Breaking?* No. *Migration:* none.
