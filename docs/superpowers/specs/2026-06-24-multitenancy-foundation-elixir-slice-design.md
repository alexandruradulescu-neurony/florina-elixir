# Slice — Multi-Tenant Database Foundation (Elixir/Phoenix)

**Date:** 2026-06-24
**Status:** Draft for review
**Repo:** `florina-elixir` (the Elixir port)
**Relationship:** Implements, in Phoenix/Ecto, the tenant-isolation contract defined for the
Django app in [2026-06-24-multitenancy-database-per-tenant-design.md](2026-06-24-multitenancy-database-per-tenant-design.md)
(Track 1). It is the foundation the realtime slices
([voice edge](2026-06-24-voice-call-realtime-edge-slice-design.md),
[live agent chat](2026-06-24-live-agent-chat-slice-design.md)) will later sit on.

---

## Summary (plain English)

Give Phoenix the ability to serve many customers while keeping each customer's data in its
own **physically separate database**. On every request the app answers two questions —
*"which customer is this?"* and *"which database is theirs?"* — and then sends all data
access to that one database, refusing the request outright if the customer can't be
identified.

This slice builds **only that machinery and proves it is safe**. It does not change the
live `/calls` or `/chat` screens, and it does not connect to any real production database.
The headline deliverable is a guarantee, demonstrated with a local test: *a request acting
as Customer A cannot read or write Customer B's database.*

## Why this is the right next step

The realtime demo that's live today is a self-contained island: one database, one tenant.
Nothing it does can safely touch real customer data until this routing layer exists. This
is the gate. It is also fully buildable and testable **locally**, with no production
credentials, so it carries no risk to the live site.

## Scope

**In:**
- A **control-plane registry**: a table listing each tenant and which database is theirs,
  plus a small context module to read and add entries.
- A **dynamic per-tenant repository** (`Florina.TenantRepo`) that can be pointed at any
  tenant's database at runtime (Ecto dynamic repositories).
- A **connection manager** that starts, caches, and reuses one connection pool per tenant.
- A **tenant-resolution plug** (and a matching LiveView `on_mount` hook) that reads the
  subdomain, looks the tenant up, pins the connection — and **fails closed** for an
  unknown/inactive tenant.
- A **per-tenant migration runner** and an operator-style **provisioning** routine
  (create database → migrate → register), used to set up two practice tenants locally.
- A tiny, throwaway **diagnostic page** so the foundation can be *seen* working in a
  browser, without touching `/calls` or `/chat`.
- **Local-only tests** (never committed): leakage, fail-closed, correct resolution,
  migrator-covers-all-tenants.

**Out (deferred to later slices):**
- Moving `/calls` or the chat onto tenant routing (the "wire a real consumer" step).
- Connecting to real production per-tenant databases (needs credentials/ops decisions).
- User accounts / per-tenant identity (the Phoenix app has none yet; only a dashboard
  password). Track 1's "where do users live" question does not apply here.
- Self-service signup, per-database backups/monitoring tooling.

## Approach — decision

**Database-per-tenant via Ecto dynamic repositories.**

| Option | Isolation | Fits the contract? | Verdict |
|---|---|---|---|
| Shared tables + a `tenant_id` column | App-enforced only; one missed filter leaks | No — contract rejects row-level | ❌ |
| Schema-per-tenant (e.g. the `Triplex` library) | Strong, but still **one** physical database | No — contract requires *physical* separation | ❌ |
| **Dynamic repositories (separate databases)** | **Strongest; physically separate DBs** | **Yes** | ✅ **Chosen** |
| One Repo module per tenant, in code | Strong | Tenants would be code, not data — can't onboard without a deploy | ❌ |

Dynamic repositories are the idiomatic Ecto mechanism for talking to many separate
databases from one app: define one repo module, start a named connection per database, and
pin the current process to the right one for the duration of the request.

## Architecture

- **Control-plane database = the existing `Florina.Repo`.** It already holds Oban's tables
  and today's call data; we add one new table, the tenant registry. (This mirrors Track 1's
  "today's database becomes tenant #1's home" idea — but for *this* slice the existing data
  simply stays put; we are not migrating it.)
- **`Florina.TenantRepo`** — a dynamic Ecto repo with **no fixed database at boot**. It is
  never started as a single always-on connection; instead the connection manager starts a
  **named instance per tenant** on demand.
- **Connection manager** — given a tenant slug, ensures a pool for that tenant's database is
  running (starting it once, reusing it thereafter) and returns the name to pin. It builds
  each connection from the app's base database settings plus the tenant's database name from
  the registry, so no per-tenant secret needs to live in the table for local use.
- **Resolution** — for HTTP, a plug; for live pages, an `on_mount` hook. Both read the
  subdomain, look up the tenant, pin `TenantRepo` to that tenant's connection
  (`put_dynamic_repo`), and stash the tenant on the conn/socket. If resolution fails, the
  request is rejected with no database access (**fail closed**).

## Data flow

```
acme.localhost / globex.localhost
        │
Resolve-tenant plug ── reads the subdomain
        │
Control-plane registry ── looks up which database is theirs
        │
Connection manager ── ensures + pins that tenant's connection
        │
TenantRepo queries ──▶ that tenant's database ONLY
        │
unknown subdomain ──▶ rejected, no database (fail closed)
```

## Components

1. **`Florina.Tenants.Tenant`** — Ecto schema for the registry row (slug, display name,
   database name, active flag).
2. **`Florina.Tenants`** — context: `list/0`, `get_by_slug/1`, `register/1`.
3. **`Florina.TenantRepo`** — the dynamic repo.
4. **`Florina.Tenants.ConnectionManager`** — ensures/caches/reuses a pool per tenant;
   resolves a slug to a started, pinnable connection.
5. **`FlorinaWeb.Plugs.ResolveTenant`** + **`FlorinaWeb.TenantHook`** (`on_mount`) — resolve
   and pin for HTTP and for live connections; fail closed.
6. **`Florina.Tenants.Migrator`** + **provisioning routine** — migrate every registered
   tenant's database; provision a new one end-to-end. Tenant-DB migrations live under their
   own migrations path (separate from the control-plane migrations).
7. **Diagnostic page** (e.g. `GET /whoami` behind the resolve-tenant plug) — shows the
   resolved tenant and a value read from *their* database. Throwaway; removed once real
   consumers are wired.

## The seam / backward compatibility (important)

This slice is **purely additive**:
- The only schema change is one new, empty table (the registry) in the existing database —
  harmless.
- `Florina.TenantRepo` stays dormant unless a tenant subdomain is actually used, so the
  app's current behaviour is unchanged.
- Existing routes (`/`, `/calls`, `/chat`, `/healthz`, the webhook) do **not** pass through
  the resolve-tenant plug, so they are untouched.
- Oban and today's call data stay on `Florina.Repo` exactly as now.
- Lands on `develop` only — **no deploy to the live site** until you give the green light.

## Tenant resolution mechanism

**Subdomain per tenant** (Track 1's recommended default): `acme.localhost`,
`globex.localhost`. Conveniently, `*.localhost` resolves to your machine with no setup, so
it is testable in a real browser. The base domain to strip is configurable (e.g. `localhost`
in dev; the real domain in production later).

## Security

- **Fail closed everywhere:** no tenant, unknown tenant, or inactive tenant ⇒ the request
  gets no database access.
- **No cross-tenant reach:** queries run against the pinned tenant connection only; there is
  no ambient default the `TenantRepo` can silently fall back to.
- Local connections are built from base config; production per-tenant credentials are a
  later, deliberate decision (out of scope here).

## Testing (local only, per project rule)

Tests are run locally and **never committed** (the `test/` folder is git-ignored).

- **Leakage (highest priority):** write a distinct marker row into Acme's database and
  another into Globex's; resolved as Acme, confirm we read Acme's marker and **cannot** reach
  Globex's — and the reverse. This mirrors Track 1's leakage test.
- **Fail closed:** a request with no/unknown/inactive tenant performs no database access.
- **Correct resolution:** `acme.localhost` pins Acme's database; `globex.localhost` pins
  Globex's.
- **Migrator coverage:** the runner migrates every registered tenant's database.

## Known gotcha to carry forward (not solved here)

When a LiveView spawns a background `Task` (the chat does this to stream tokens), that task
is a *separate process* and will **not** inherit the pinned tenant connection. When we later
wire real consumers, the tenant must be re-pinned inside such tasks. Flagged now so it isn't
a surprise later.

## Open decisions (confirm during planning)

1. **Connection-manager shape** — a simple GenServer holding a slug→pool map, vs. a
   `DynamicSupervisor` + `Registry`. Either is fine for a handful of tenants; pick the
   simplest in the plan.
2. **Diagnostic page** — keep the tiny `/whoami` proof page, or rely on tests alone.
   (Recommended: keep it — it lets you *see* isolation in a browser.)
3. **Marker table name/shape** for the leakage proof — name it during planning.

## Out of scope

- Wiring `/calls` or the chat onto tenancy; real production databases; user accounts;
  signup; per-database ops tooling. Each is a separate, later decision.
