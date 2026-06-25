# Slice — Onboarding the Second Customer (Phoenix, self-contained)

**Date:** 2026-06-25
**Status:** Draft for review
**Repo:** `florina-elixir` (the Elixir port)
**Relationship:** Builds on the
[multi-tenant database foundation](2026-06-24-multitenancy-foundation-elixir-slice-design.md).
The live Django app and the [Track 1 Django design](2026-06-24-multitenancy-database-per-tenant-design.md)
are **reference only** — we read them to understand the product's behaviour; Phoenix does
**not** integrate with, connect to, or depend on Django at runtime.

---

## Summary (plain English)

Make the Phoenix app serve multiple customers, each with their own database — **entirely
within Phoenix**. Phoenix creates, owns, migrates, and connects to each customer's database
itself, all on its existing Railway Postgres. There is no Django at runtime and no
cross-server access.

## Decisions

1. **Topology:** separate database per customer on Phoenix's **existing Railway Postgres
   instance** (same server + credentials; only the database name changes per customer).
2. **Ownership:** Phoenix owns the per-tenant schema and data end to end. No Django
   integration; no second server.

## Bucket A — One-time engineering (build once, enables every customer)

- **A1 · Production connection wiring.** Today the connection manager only builds tenant
  connections from *local-style* settings (empty in prod, which uses a single `DATABASE_URL`).
  Add a production path: derive the base connection (host, user, password, port) from
  `DATABASE_URL` and override only the database name per tenant. Local dev unchanged.
- **A2 · Make a real feature multi-tenant (the calls flow).**
  - Move the per-tenant call table (`voice_callattempt`) into the **tenant** migration path
    (`priv/tenant_repo/migrations`) so every provisioned customer database gets it. The
    control-plane database keeps only the `tenants` registry + Oban.
  - **Write path:** route the ElevenLabs webhook by **subdomain** (reuse the `ResolveTenant`
    plug) so an incoming call is written into the right customer's database.
  - **Read path:** resolve + pin the tenant on the `/calls` LiveView via the `on_mount` hook
    (the one deferred from the foundation), and read from the tenant connection.
  - **Reset the per-request pin** (the stale-pin gotcha) and **re-pin inside spawned `Task`s**
    (the chat streamer is the known case).
- **A3 · Existing customer → tenant #1.** Provision tenant #1, bring the current call data
  across into its database, register it, and give it a subdomain. Existing behaviour preserved.

## Bucket B — Per-customer runbook (repeatable, Phoenix-only)

| # | Step | Owner |
|---|---|---|
| 1 | **Provision the customer** — one command: create database → migrate Phoenix schema → register. Phoenix's existing `Provisioner` already does this. | Phoenix (me) |
| 2 | **Point their subdomain** at the app — Railway / DNS | You / ops |
| 3 | **Verify isolation, then go live** — fail-closed + leakage checks | Me |

There is **no Django step**. The only non-code step is pointing the subdomain.

## Retire the throwaway scaffolding

The foundation's `tenant_markers` table and `/whoami` page were proof-of-life scaffolding.
A2 replaces them with the real per-tenant schema; remove both as part of A2.

## Sequencing

A1 → A2 → A3 (build once, then deploy) → run Bucket B per customer.

## Security / testing (local-only, per project rule)

Reuse the foundation's **leakage** and **fail-closed** tests and extend them to the wired
calls flow: a webhook or page resolved as tenant A only ever touches tenant A's database.
Cover the **stale-pin reset** (a second request on a reused process must not inherit tenant
A's pin) and the **task re-pin**. Per-customer go-live: verify isolation before pointing the
subdomain.

## Open decisions (confirm during planning)

1. **Webhook tenant routing:** by subdomain (recommended — reuses the plug; needs ElevenLabs
   configured with a per-tenant subdomain URL) vs. a tenant id carried in the call metadata.
2. **Tenant #1 existing data:** migrate existing calls into tenant #1's database, vs. start
   tenant #1 fresh.

## Out of scope

- Separate Postgres instance per customer; self-service signup; per-database
  backups/monitoring tooling.
- Data-grounded chat (a separate slice).
- **Any Django runtime integration** — reference only; explicitly not a dependency.
