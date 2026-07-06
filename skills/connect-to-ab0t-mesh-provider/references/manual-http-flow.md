# Manual HTTP flow (what `authsetup connect` automates)

Use this when the binary can't run (a non-Go/other-language client, no install
rights) or you want to see exactly what happens. `connect` does these calls with
retries, idempotency, and a redacted journal — prefer it when available.

The provider ran `run 08` once, which created a `{service}-api-consumers` org
with `signup_enabled` and a default tier team you auto-join on registration.

## 0. (optional) Discover the provider

```sh
curl -s https://auth.service.ab0t.com/mesh/providers | jq .
# or one provider (resolves even if unlisted):
curl -s https://auth.service.ab0t.com/mesh/providers/billing | jq .
```

Take `consumer_registration.org_slug`, `.register_url`, and a tier's
`.permissions`.

## 1. Register a consumer account (no provider creds)

Org-scoped register — the same endpoint a human uses for hosted-login signup,
called with a non-human email. Auto-joins the org's default tier team.

```sh
curl -X POST https://auth.service.ab0t.com/organizations/billing-api-consumers/auth/register \
  -H "Content-Type: application/json" \
  -d '{"email":"my-svc@my-org.consumers","password":"SecurePass2026@"}'
# -> {"access_token":"...", "user_id":"..."}
```

Store the password in your own secrets manager — you need it to log in again.

## 2. Mint a scoped API key

Request permissions ⊆ the tier. Auth **403s** any permission your team
membership doesn't grant ("Cannot create API key with permissions you don't
hold"). Request exactly the default tier's published permissions.

```sh
TOKEN=<access_token from step 1>
curl -X POST https://auth.service.ab0t.com/api-keys/ \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"my-svc -> billing","permissions":["billing.read","billing.read.accounts"]}'
# -> {"id":"...","key":"ab0t_sk_live_...","permissions":[...]}   shown ONCE
```

> **Privileged perms are NOT in the default tier.** `cross_tenant` / `cross_org` /
> `global.*` cross tenant boundaries and are **explicit-only** — a provider's
> `default:true` / open-signup tier never carries them. If your service is a
> genuine multi-org gateway that needs `billing.cross_tenant`, the provider must
> add your account to an explicit `default:false`, `privileged_ack:true`
> "Cross-Tenant (invite)" tier first (see "Re-runs / rotation" below and
> `mesh-consumer-account-sop`). Requesting it before you hold it → 403. Ref:
> ticket `20260706_cross_tenant_privilege_guardrails`.

Save `key` securely — it is not retrievable again.

## 3. Use it

```sh
curl -H "X-API-Key: ab0t_sk_live_..." https://billing.service.ab0t.com/...
```

## Re-runs / rotation

To re-authenticate later, `POST /auth/login {email,password}` (the account you
made in step 1), then repeat step 2. Revoke a key with
`DELETE /api-keys/{id}`. Keys minted for higher tiers require the provider to
add your account to that tier's team first (`mesh-consumer-account-sop`,
"Upgrading a Consumer's Tier").
