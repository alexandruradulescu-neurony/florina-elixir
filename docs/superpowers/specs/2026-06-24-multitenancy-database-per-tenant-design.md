# Multitenancy — Database-per-Tenant (Track 1)

**Date:** 2026-06-24
**Status:** Draft for review
**Repo:** `neurony/florina` (the **live Django app** — this repo)
**Relationship:** Defines the tenant-isolation contract that the Elixir port ([2026-06-24-elixir-phoenix-port-design.md](2026-06-24-elixir-phoenix-port-design.md)) must later honor.

---

## Summary (plain English)

Let the application serve multiple customers from one running system while keeping each customer's data in its own **physically separate database**. A real, near-term customer requires this level of isolation by contract, so it is urgent and revenue-critical, and it is built on the proven Django stack rather than waiting on the Elixir port.

Because the live app today serves essentially **one customer**, its current production database simply becomes the first customer's database — there is no commingled data to untangle.

## Why this matters / drivers

- **A specific near-term customer requires it**, with **strict, contractually-required physical isolation** (separate database — potentially for data residency, separate backups, or separate encryption keys).
- Customer-driven and time-sensitive → must ship on the customer's timeline, on a stack the team already runs in production.
- **Never put a customer commitment behind the discretionary Elixir rewrite.** This work stays in Django.

## Isolation model — decision

**Database-per-tenant**, chosen over the two lighter alternatives:

| Model | Isolation | Ops weight | Verdict |
|---|---|---|---|
| Shared tables + tenant tag (row-level) | App-enforced only; one missed filter leaks data | Lightest | ❌ Too weak for strict isolation |
| Schema-per-tenant (one DB, walled-off sections) | Strong, DB-enforced | Moderate | ❌ Customer requires *physical* separation |
| **Database-per-tenant** | **Strongest; physically separate DBs** | Heaviest | ✅ **Chosen — contract-required** |

### What database-per-tenant entails

The standard pairing:

1. **A small control-plane database** owned by the app: the registry of which tenants exist, which database each lives in, connection info, and cross-customer concerns (billing, global admin).
2. **One separate database per customer** holding all of that customer's data.

On every request the app: identifies the customer → looks up their database in the control-plane registry → routes all reads/writes to that customer's database for the rest of the request.

**Accepted trade-off:** more databases to run, back up, migrate, and monitor, plus a provisioning step per new customer. Justified by the contractual requirement; recorded here so it is an informed commitment.

## Architecture

- **Control-plane DB** (`default` / shared connection): tenant registry, and — pending the auth decision below — user accounts.
- **Per-tenant DBs**: one connection per customer, resolved dynamically per request via Django's multi-database support + a database router.
- **Tenant resolution middleware**: resolves the current tenant early in the request, stores it in request-local context, and the router reads it to direct queries.
- **Migrations**: applied to the control-plane DB and to each tenant DB in turn (manageable with few tenants).
- **Provisioning workflow**: create DB → run migrations → seed → register in control-plane.

## Data flow

```
Request ──▶ Tenant-resolution middleware ──▶ control-plane registry lookup
                                              │
                                              ▼
                              DB router pins this request's queries
                                              │
                                              ▼
                                  Customer's own database
```

## Delivery phases

### Phase A — Tenancy plumbing (invisible to the current customer)
Add the control-plane database, tenant-resolution middleware, and the database router. Register **today's production database as "tenant #1."** The app behaves exactly as it does now (single tenant), but is tenancy-capable. Low-risk, shippable, the existing customer notices nothing.

**Done when:** the live app runs unchanged in behavior, but all queries flow through tenant routing with the existing DB as tenant #1.

### Phase B — Onboard the new customer
Build the provisioning workflow and bring the new customer on: create their database, set up its tables, register them, configure their access.

**Done when:** the new customer operates fully on their own isolated database; both customers coexist with zero data crossover.

## Open decisions (need confirmation before/while writing the plan)

1. **Tenant resolution mechanism** — how a request identifies its customer.
   - *Recommended default:* **subdomain per tenant** (e.g. `acme.yourapp.com`) — standard for B2B, clean separation, works before login. Alternative: authenticated-user → tenant mapping (simpler, but can't resolve pre-login pages).
2. **Where user accounts live** — the app currently keeps users in the main database (`AUTH_USER_MODEL = voice.User`).
   - *Recommended default:* **users in the control-plane database**, each linked to the tenant(s) they may access — keeps a single identity surface and eases future single sign-on. Alternative: replicate users inside each tenant DB (stronger isolation of identity, harder cross-tenant admin).
3. **Migration of the existing DB** — confirm the mechanism for the current production DB physically *becoming* tenant #1's DB vs. provisioning a fresh tenant #1 and migrating data into it.

## Testing strategy

- Tests run **locally only** (project rule: no committed tests).
- Cover: tenant resolution picks the right DB; the router never lets a query reach the wrong tenant's DB; a request with no/invalid tenant fails closed (no data); provisioning produces a correctly-migrated, isolated DB.
- Cross-tenant leakage test is the highest priority — attempt to read tenant B's data while resolved as tenant A and assert it is impossible.

## Risks

- **Cross-tenant data leakage** — the entire point; mitigated by fail-closed routing + the leakage test above.
- **Migration drift across tenant DBs** — a tenant DB missing a migration. Mitigated by a migration runner that iterates all registered tenants and a check that flags drift.
- **Operational overhead** — accepted; revisit tooling (backups, monitoring per DB) as tenant count grows.

## Out of scope

- The Elixir/Phoenix port (separate spec).
- Billing/metering beyond the control-plane registry stub.
- Self-service customer signup (Phase B is operator-driven onboarding).
