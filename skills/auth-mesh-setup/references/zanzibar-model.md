# Zanzibar Permission Model

How parent orgs, teams, and permission inheritance work in Auth Mesh.

## Core Idea

Auth Mesh uses Google Zanzibar (relation-based access control). Permissions are structural — they flow through relationships, not per-user grants.

```
User → member of → Org → has team → Team → has permissions → [permission IDs]
```

Permission checks walk this chain at query time. No cron jobs, no sync, no per-user records.

## The Parent Relationship

When step 04 creates the end-users org with `parent_id = service_org_id`, auth automatically writes:

```
organization:{end-users-org}#parent@org:{service-org}
```

This Zanzibar tuple means permission checks on the end-users org can walk up to the service org. It's what makes the hierarchical permission model work.

## Team-Based Inheritance

```
Service Org
  └── End-Users Org (parent_id = service org)
        └── Default Team
              ├── permissions: [sandbox.create.sandboxes, sandbox.read.sandboxes, ...]
              └── members: [User A, User B, User C, ...]
```

When a user registers:
1. User joins end-users org as `member` role
2. Login config `default_team` triggers auto-join to Default Team
3. User inherits all permissions assigned to the team

### Why Teams, Not Direct Grants?

| Approach | Scale | Maintenance | Revocation |
|----------|-------|------------|------------|
| Per-user grants | O(users × permissions) records | Manual per-user | Must find and delete each grant |
| Team membership | O(1) team record + O(users) memberships | Add/remove team perms once | Remove from team = lose all perms |

Teams scale to millions of users without per-user permission records.

## Permission Check Flow

When AuthGuard checks if a user has a permission:

```
1. Get user's org memberships
2. For each org, get user's team memberships
3. For each team, get team's permissions
4. Walk parent org relationships for inherited permissions
5. Union all permissions → check if requested permission is in the set
```

This happens via `GET /permissions/user/{user_id}` or during JWT validation.

## Two Permission Registrations

Step 01 registers the permission schema on the **service org**.
Step 04 registers the same schema on the **end-users org**.

Both are needed because:
- Service org registration: defines what permissions exist globally
- End-users org registration: enables `GET /permissions/user/{user_id}` queries scoped to the end-users org

Without the second registration, permission lookups in the end-users org context return empty.

## default_grant vs Explicit Grant

```json
{
  "id": "sandbox.read.sandboxes",
  "default_grant": true          ← flows through team membership automatically
}

{
  "id": "sandbox.admin",
  "default_grant": false         ← admin must grant explicitly
}
```

- `default_grant: true` permissions are assigned to the Default Team in step 04
- New users auto-join the team → get these permissions immediately
- `default_grant: false` permissions require `POST /permissions/grant` for specific users

## The implies Chain

```json
{
  "id": "sandbox.admin",
  "default_grant": false,
  "implies": ["sandbox.create.sandboxes", "sandbox.read.sandboxes", ...]
}
```

When `sandbox.admin` is granted to a user (step 01 does this for the admin), all `implies` permissions are also granted. This is a direct grant, not team-based — it applies only to the specific user.

## Org Isolation

Each service enforces org isolation using the AuthGuard `belongs_to_org` callback:

```python
# In your service's auth module
async def belongs_to_org(user: AuthenticatedUser, org_id: str) -> bool:
    return user.org_id == org_id
```

Cross-org access requires a specific permission (e.g., `sandbox.cross_tenant`), which is typically only granted to service accounts via API keys, not to regular users.

## What Zanzibar Gives You

- **No per-user permission sync** — permissions are computed from relationships at check time
- **Instant effect** — add a user to a team → they have permissions immediately
- **Instant revocation** — remove from team → permissions gone immediately
- **Scalable** — same model as Google (Zanzibar), GitHub (org/team), Slack (workspace)
- **Auditable** — relationships are explicit and queryable
