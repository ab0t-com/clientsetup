---
name: billing-payment-consumer-setup
description: >-
  Get the keys a service needs to charge its own customers through the ab0t mesh billing and payment
  services, and know which permissions to ask for. Use when a team wants its product to record usage,
  check a customer's balance, reserve and commit funds, sell plans, open a checkout or the customer
  portal, or manage subscriptions on behalf of its customers, and needs scoped billing/payment keys to
  do it: `authsetup providers`, `authsetup connect billing|payment --as <service>`, the read-only
  default tier, asking the provider for the metering/checkout (cross-customer) tier, wiring
  BILLING_SERVICE_API_KEY / PAYMENT_SERVICE_API_KEY or the quota library's AB0T_QUOTA_* names, and
  "403 different organization" on a customer's org. Routes to the Ally SOP 11 and the billing-quota
  bot (Penny) SOPs for the full procedure.
---

# Charge your customers through billing and payment

## What this is

Your service becomes a **consumer** of two mesh services: **billing** (the ledger: balances, usage,
reservations) and **payment** (plans, prices, checkout, the customer portal, subscriptions; it owns
Stripe, so you never touch a card). Each gives your service its own scoped key, so you can charge your
customers without building a billing system or holding anyone else's credentials.

## The picture

```
your customer ──► your API ──(X-API-Key: your billing key)──► billing   records usage / balance for the CUSTOMER's org
                     │
                     └───────(X-API-Key: your payment key)──► payment   checkout, portal, subscriptions → Stripe
```

| key | what the default tier allows | what you add by asking the provider |
|---|---|---|
| billing | read: balances, usage, transactions, reports | `billing.write.usage` (metering) · `billing.write.reservations` + `billing.write.transactions` (reserve / commit) · `billing.write.refunds` (release) |
| payment | read: plans, prices, invoices, subscriptions | `payment.write` (checkout, subscriptions, saving a card) |
| both | your own org only | the provider's **cross-customer tier**, to act on your customers' orgs |

The customer who pays is always **the customer's org**, never yours. One key acting for many customers
is what a gateway does; it needs the provider's approval, not a workaround (`mesh-tenancy-authority`).

## Do this (the default path, dev first)

```sh
authsetup --env dev providers                                  # billing and payment cards, tiers, permissions
authsetup --env dev connect billing --as invoicer --dry-run
authsetup --env dev connect billing --as invoicer
authsetup --env dev connect payment --as invoicer             # same --as: one identity for both
```
1. Each key is saved `0600` to `~/.authmesh/invoicer/<provider>-consumer.dev.json` (field
   `.api_key.key`) and is **never printed**. Move it into your secrets manager.
2. Set the two lines `connect` prints per provider (`BILLING_SERVICE_URL`, `BILLING_SERVICE_API_KEY`;
   the same for payment). Off production the URL is left empty on purpose: ask the provider for that
   environment's address. The Go quota library reads `AB0T_QUOTA_BILLING_URL` / `AB0T_QUOTA_BILLING_TOKEN`
   and `AB0T_QUOTA_PAYMENT_URL` / `AB0T_QUOTA_PAYMENT_TOKEN`; the Python library reads
   `AB0T_MESH_API_KEY` and `AB0T_CONSUMER_ORG_ID`.
3. Ask the provider to upgrade your consumer account (the `connect` output names it) with one sentence
   about what you do ("invoicer records usage and starts checkouts for its customers' orgs") and only
   the permissions in the table you will use. Do not ask for `billing.admin` / `payment.admin` unless
   you administer plans yourself. Then re-run `connect`; it adopts the account and re-mints the key.
4. On every call: your key as `X-API-Key`, the customer's `org_id` taken from the **validated** user
   token (never from the request), the key kept server-side.
5. Build the money flow with the billing-quota bot (**Penny**):
   `curl -fsSL https://raw.githubusercontent.com/ab0t-com/bots/main/billing-quota/install.sh | sh`.
   Its SOPs: 01 the money model · 03 get your keys · 05 wire the quota library · 07 plans, checkout,
   portal · 08 subscriptions and webhooks · 11 metering with billing · 12 multi-tenant correctness.

## What your customers notice

- Nothing about keys: they see your pricing page, Stripe's checkout and portal, and their balance in
  your app. Card details never touch you or your logs.
- Each customer is charged on their own org; one customer never sees another's balance or invoices,
  provided you always take `org_id` from their validated token.
- If billing or payment is unreachable, answer `503` ("try again"), never a silent success or a free
  pass; a key without the right tier gives you a `403` to fix, not something to show the customer.

## Common mistakes (and what you will see)

| mistake | what you see | fix |
|---|---|---|
| metering on the read-only tier | `403 {"error":"PERMISSION_DENIED","message":"One of permissions required: billing.write.usage, …"}` | step 3 |
| acting on a customer's org without the cross-customer tier | `403 … "Access denied - different organization"` (billing) / `"Access denied to organization data"` (payment) | step 3 |
| asking `connect` for a higher tier before the provider moved you | `provider "billing" did not grant every permission tier "Standard Consumers" requests — …` | connect on the default tier, then step 3 |
| billing's key sent to payment | `401` from payment | keys are per provider |
| forwarding the user's bearer token | `401` / wrong audience | send your own key |
| a dev key pointed at production | — (it fails or, worse, hits prod) | never guess a URL; ask the provider |

## Check it worked

```sh
authsetup --env dev status --verify     # one row per connection: ◐ WIRED → ● LIVE (⨯ FAILED if revoked)
curl -sS "$BILLING_SERVICE_URL/health"   # 200 = the service is up
```
(`/health` is public on both services: a `200` there only says the service is up.)
Rotate or leave with `authsetup --env dev disconnect billing --as invoicer --dry-run` (SOP 14). Never
delete `~/.authmesh/invoicer/`; it holds every environment, prod included. Still stuck: send
`authsetup --env dev doctor --json`, `status --json` and the failing output to `platform-team@ab0t.com`
(never a key or credentials file).

## Related

Ally SOPs (in `authmesh/`): [11 using other services](../../11_sop_system_using_other_services.md) ·
[14 keys](../../14_sop_system_keys_rotate_offboard_disconnect.md) ·
[16 troubleshooting](../../16_sop_system_troubleshooting_and_recovery.md) ·
[17 security rules](../../17_sop_system_security_rules.md). Skills: `mesh-consumer-account-sop` (any
provider) · `mesh-tenancy-authority` (why a gateway needs the cross-customer tier) ·
`connect-to-ab0t-mesh-provider` (`connect` in detail).
