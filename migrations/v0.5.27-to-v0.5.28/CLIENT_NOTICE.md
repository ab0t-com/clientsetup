# authsetup 0.5.28 — what changes for you

Nothing breaks. Upgrade with `authsetup update`.

- **Service names without `_`.** The auth service drops `_` from the org names it creates, so a new setup named, for
  example, `nw_rent` failed at its first run (step 05: sign-in page not found). authsetup no longer generates such
  names, and `authsetup validate` now warns if yours has one. If your setup already works, nothing changes. If you are
  about to create one, use letters and digits only, in all four places (`service.id`, `service.audience`,
  `registration.service`, every permission prefix).
- **Ally answers four questions** new setups get stuck on: one shared users org or a workspace per user (and what your
  backend must check in each), whether the validate calls need your service key (no), what `ADMIN_EMAIL` is for (it
  gets the admin's password-reset mail, so use a real mailbox), and how to choose the service name. Refresh it with
  `authsetup bot install`.

Check a repository in one step: `./migrate-check.sh /path/to/your/repo` (from the `v0.5.27-to-v0.5.28` kit).
