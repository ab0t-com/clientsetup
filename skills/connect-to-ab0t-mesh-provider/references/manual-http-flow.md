# Manual HTTP flow (what `authsetup connect` automates)

Use this only when the binary cannot run (no install rights, an unusual platform) or you want to see
exactly what happens. `connect` does the same calls with retries, idempotency, the production guard and
a redacted journal; prefer it. The examples use dev; production is `https://auth.service.ab0t.com`.

The provider opened self-serve once (its `run 08` with `registration.signup_enabled: true`), which made
a `{service}-api-consumers` org whose default tier team you join on registration.

## 0. Discover the provider (optional)

```sh
curl -s https://auth.dev.ab0t.com/mesh/providers | jq .
curl -s https://auth.dev.ab0t.com/mesh/providers/billing | jq .     # one provider, even if unlisted
```
Take `consumer_registration.org_slug`, `.register_url`, and the default tier's `.permissions`.

## 1. Register a consumer account (no provider credentials)

The org-scoped register endpoint, called with a non-human address. It joins the default tier team.
```sh
curl -s -X POST https://auth.dev.ab0t.com/organizations/billing-api-consumers/auth/register \
  -H "Content-Type: application/json" \
  -d '{"email":"my-svc@my-org.consumers","password":"<a long random password you generate>"}'
# -> {"access_token": "...", "user_id": "...", ...}
```
Keep the password in your secrets manager; you need it to sign in again. Never put it in a script you
commit.

## 2. Mint a scoped API key

Ask for permissions that are a subset of your tier (the default tier's published list). The auth
service refuses anything you do not hold (`403 … Cannot create API key with permissions you don't hold`).
```sh
curl -s -X POST https://auth.dev.ab0t.com/api-keys/ \
  -H "Authorization: Bearer <access_token from step 1>" \
  -H "Content-Type: application/json" \
  -d '{"name":"my-svc -> billing","permissions":["billing.read","billing.read.accounts"]}'
# -> {"id": "...", "key": "ab0t_sk_live_...", "permissions": [...]}   the key is shown ONCE
```
Store `key` in your secrets manager straight away; it cannot be retrieved again.

A permission that reaches across the provider's customers is never in a default tier. If your service
genuinely acts for many customers' orgs, the provider must first move your account into its
invite-only tier (Ally SOP 12 step 4 is the provider's side); asking before that gets a `403`.

## 3. Use it

```sh
curl -s -H "X-API-Key: $BILLING_SERVICE_API_KEY" https://<billing URL for this environment>/health
```

## Later

Sign in again with `POST /auth/login {email, password}` (the account from step 1) and repeat step 2 to
mint a new key; revoke an old one with `DELETE /api-keys/{id}` using that same sign-in. A key for a
higher tier needs the provider to add your account to that tier's team first.
