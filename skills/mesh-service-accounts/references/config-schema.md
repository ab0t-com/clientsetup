# `config/clients.d/<provider>.json` — the in-house consumer file

Use this only when you run **both** services and hold the provider's admin credentials file (for
example Acme's `invoicer` calling Acme's own `reports` service). Everyone else uses
`authsetup --env <env> connect <provider> --as <you>` and needs no file at all (Ally SOP 11).

One file per provider, in your config directory:
```
config/
└── clients.d/
    ├── reports.json
    └── archive.json
```
`authsetup --env dev --config-dir ./config run 07` reconciles **every** `*.json` in that folder on each
run. Preview first (`--dry-run`) and read the whole plan.

## Example

```json
{
  "provider": {
    "service_id": "reports",
    "service_name": "Acme Reports",
    "credentials_path": "~/.authmesh/reports/reports.dev.json",
    "service_url": "https://reports.acme.example"
  },
  "client": {
    "service_id": "invoicer",
    "service_name": "Invoicer",
    "customer_org_name": "Invoicer - Reports Customer",
    "customer_org_slug": "reports-customer-invoicer",
    "service_account_email": "invoicer@reports.customers",
    "service_account_password": ""
  },
  "permissions": [
    "reports.read",
    "reports.read.summaries"
  ],
  "api_key": {
    "name": "invoicer-reports-backend",
    "rate_limit": 10000,
    "metadata_purpose": "Invoicer backend reads report summaries for its signed-in users"
  }
}
```

## Fields

**`provider`**

| field | meaning |
|---|---|
| `service_id` | the provider's `service.id` (its `permissions.json`) |
| `service_name` | display name, used in output |
| `credentials_path` | **absolute** path to the provider's admin credentials file for the same environment (`<provider>.<env>.json`); `run 07` signs in as that admin to create your sub-org. Without it: `co-located mode needs the provider's creds file` — use `connect` instead |
| `service_url` | the provider's base URL, recorded in your output file for reference |

**`client`**

| field | meaning |
|---|---|
| `service_id` | your service's id; keep it the **same** in every `clients.d` file so all your keys sit under one identity |
| `service_name` | your display name |
| `customer_org_name` | the sub-org created for you under the provider; convention `"{You} - {Provider} Customer"` |
| `customer_org_slug` | its slug; convention `"{provider}-customer-{you}"`; must be unique |
| `service_account_email` | an identifier, not a real inbox; convention `"{you}@{provider}.customers"` |
| `service_account_password` | **leave empty**: the tool generates one and keeps it in your credentials folder. Never commit a real password here (SOP 17) |

**`permissions`**: the permission ids your key should carry; each must exist in the provider's
registered schema. Ask for the least you need. A cross-customer (`platform`) permission must be
requested explicitly and sanctioned by the provider's admin (SOP 11 step 6: `privileged_tier`,
`privileged_ack: true`, `privileged_perms`); it is never part of a default.

**`api_key`**: `name` (convention `"{you}-{provider}-backend"`), `rate_limit` (requests per hour;
10000 is a sensible backend default), optional `metadata_purpose` (stored with the key for audits).

## What a run does with it

For each file: creates (or finds) your sub-org under the provider and a service account in it, then
mints a key holding exactly `permissions` and saves it to `~/.authmesh/<you>/<provider>-consumer.<env>.json`
(0600). A re-run reuses the key while its recorded permissions match the file; any change mints a new
key, and the old one keeps working until you revoke it (SOP 14).
