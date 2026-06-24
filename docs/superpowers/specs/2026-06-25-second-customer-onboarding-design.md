# Slice — Onboarding the Second Customer (end-to-end map)

**Date:** 2026-06-25
**Status:** Draft for review
**Repo:** `florina-elixir` (the Elixir port) — plus documented dependencies on the live
Django app and production ops.
**Relationship:** Builds on the
[multi-tenant database foundation](2026-06-24-multitenancy-foundation-elixir-slice-design.md)
and consumes the [Track 1 database-per-tenant contract](2026-06-24-multitenancy-database-per-tenant-design.md).
Strangler-fig: **Django stays the brain** (owns each customer's data + schema); **Phoenix is
the realtime edge** that connects to those same per-customer databases.

---

## Summary (plain English)

Take the live system from one customer to two, with each customer's data in its own database.
The key realisation: **most of the work is one-time engineering** that enables *every* future
customer; after that, onboarding a customer is a **short, repeatable runbook**, and several of
its steps live on the Django + Railway side, not in this Phoenix sandbox.

## Decisions made (in brainstorming)

1. **Database topology:** **separate database per customer on a single shared Postgres
   instance** (not a separate Postgres server per customer). Cheapest/simplest; fits a "their
   data in its own database" contract. Per-customer connections therefore reuse the same
   server + credentials and only swap the database name.
2. **Data access:** Phoenix connects **directly** to each customer's shared database. Django
   creates and owns the schema and data (calls, clients, visits, …). Going through a Django
   API instead is cleaner long-term but slower; recorded as future work, not chosen now.

## Bucket A — One-time engineering (Phoenix; build once)

This is the real work and it is what a build plan will cover.

- **A1 · Production per-tenant connection wiring.** Today the connection manager can only
  build a tenant connection from *local-style* discrete settings, which are empty in prod
  (prod uses a single `DATABASE_URL`). Add a production path: derive the base connection
  (host, user, password, port) from `DATABASE_URL`, and per tenant override only the database
  name. Local dev keeps its current behaviour.
- **A2 · Wire real consumers to the resolved tenant.** Make a real screen actually use
  tenancy, starting with `/calls`:
  - Build the **LiveView `on_mount` tenant hook** deferred from the foundation (resolve +
    pin at mount, from the socket's host).
  - **Reset the per-request connection pin** (the stale-pin gotcha recorded in the foundation
    spec) so a reused web-server process can never serve a previous request's tenant.
  - **Re-pin inside spawned `Task`s** (the chat's streaming task is the known case).
  - Point `Florina.Calls`' reads/writes at the **tenant connection** instead of the fixed
    `Florina.Repo`.
- **A3 · Bring the existing customer on as "tenant #1".** Their current database simply
  *becomes* tenant #1's database (per Track 1). Register it, give it a subdomain. Their
  experience is unchanged, but all access now flows through tenant routing — this also retires
  the current single-database "island".

## Bucket B — Per-customer runbook (repeatable)

| # | Step | Owner |
|---|---|---|
| 1 | **Create their database** — one `CREATE DATABASE` on the shared Postgres instance | You / ops |
| 2 | **Load schema + data** — run the Django migrations + seed into that database | The live **Django app** (not this sandbox) |
| 3 | **Register the tenant in Phoenix** — one registry row (subdomain → database name) | Phoenix (small; existing provisioning command, adapted) |
| 4 | **Point their subdomain** at the app — DNS + Railway routing | You / ops |
| 5 | **Verify isolation, then go live** — fail-closed + leakage checks against the new tenant | Me (Phoenix) |

## Sequencing

1. **Build Bucket A once** (A1 → A2 → A3), verified locally and then deployed.
2. **Run Bucket B** for customer #2 (and every customer after).

## Provisioning adaptation (important)

The foundation's `Provisioner` creates a database **and runs Phoenix's own tenant migrations**
(the throwaway `tenant_markers` table). For a **real** customer in the shared model the database
and schema belong to **Django**, so Phoenix must **not** create or migrate that schema.
Phoenix's provisioning for a real tenant becomes: **register only** (and migrate only any tables
Phoenix itself owns in that database, if any). The throwaway `tenant_markers` table and the
`/whoami` page are retired as part of A2.

## Dependencies / to confirm (infrastructure)

These are real-world facts to nail down before/while building — they depend on how the live
Django app is hosted, which is outside this sandbox:

- **Which Postgres instance holds the customer databases, and that Phoenix can reach it.** The
  shared per-customer databases must live on a Postgres server Phoenix can connect to (network
  access + credentials). If the live Django database is not the same Postgres that Phoenix's
  `DATABASE_URL` points at, Phoenix needs credentialed access to that server.
- **How each tenant's connection is provided in prod.** Recommended: derive from the base
  `DATABASE_URL` (same instance + credentials, swap database name). If a tenant ever needs
  *different* credentials, store a per-tenant URL as a secret referenced by the registry row.
- **The Phoenix control-plane database** (the `tenants` registry + Oban) stays on Phoenix's
  current database and must be distinct from the per-customer databases.

## What stays OUT of this sandbox

- All live **Django repo** work — creating/migrating the customer's schema, Django-side config
  (`neurony/florina`, the live app). This spec documents what it must do; I will not touch it.
- Real production **ops** — DNS changes, Railway changes, running live migrations. Documented;
  run by you.

## Security / testing (local-only, per project rule)

- Reuse the foundation's **leakage** and **fail-closed** tests, and extend them to the wired
  `/calls` path: a connection resolved as tenant A returns only tenant A's calls, never tenant
  B's. Cover the stale-pin reset (a second request on a reused process must not inherit tenant
  A's pin) and task re-pin.
- **Per-customer go-live check (Bucket B step 5):** verify isolation against the new tenant
  (ideally on staging data) *before* pointing the subdomain.

## Risks

- **Cross-tenant leak via a stale pin** if A2's reset is missed — mitigated by the reset +
  tests; this is the highest-priority correctness item.
- **Phoenix reaching the customer databases** (network/credentials/permissions) — the main
  infrastructure dependency above.
- **Cutover of the existing customer (A3)** — verify customer #1 still works exactly as before
  after they become tenant #1.

## Out of scope

- Separate-Postgres-instance-per-customer topology (deliberately not chosen now).
- Self-service signup; per-database backups/monitoring tooling.
- Data-grounded chat (a separate slice); going through a Django API instead of direct DB access.
