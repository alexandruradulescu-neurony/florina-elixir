# Central Configuration Distribution (control-plane → tenants)

**Date:** 2026-06-25
**Status:** Design agreed; build on green light
**Repo:** `florina-elixir`
**Relationship:** Refines the [multi-tenant foundation](2026-06-24-multitenancy-foundation-elixir-slice-design.md)
and the [backend port](../plans/2026-06-25-backend-port.md). Today all config is per-tenant;
this introduces a central config layer.

---

## Summary (plain English)

Author the product's **platform configuration once, centrally** (in the main / control-plane
database), and push it down to every customer's database. Each customer's **private data
stays in their own database** and is never shared. A customer may **override** a central
default locally.

## Decision — the split

**Central (authored once in the control-plane DB, pushed to all tenants):**
- Mega-prompts (assembler engine prompts)
- Voice prompts (AI agent system prompts)
- Methodology library
- Scenarios
- Default settings (call offsets, retry interval, token-warn threshold)

**Per-tenant (private; never shared):**
- Clients, Visits, CallAttempts, Users/agents, GenerationRuns (audit), ActivityLog,
  Google calendar credentials + watches.

**Override:** a tenant-local override wins over the central default. Effective value =
`tenant override ?? central default`.

## Model

Because each customer is a *physically separate* database, tenants can't cheaply read the
central DB at query time (no cross-database joins). So:

1. **Canonical** config lives in the control-plane database (`Florina.Repo`).
2. **Seed on provision:** provisioning a new tenant copies the current central config into it.
3. **Publish on edit:** editing central config runs a `publish` that upserts the change into
   every registered tenant's local copy.
4. Each tenant keeps a **synced local copy**, so all in-app lookups stay within one database.
5. Reads resolve **tenant override → central default**.

## Implications for the current build

- The config schemas (mega prompts, voice prompts, methodologies, scenarios, global settings)
  currently exist **only per-tenant**. This adds a **control-plane copy** of those tables
  (the canonical source) + a publish/seed mechanism.
- `Florina.Tenants.Provisioner` seeds new tenants from the central config.
- The relevant contexts gain an "effective value (override-aware)" read path.
- A `Florina.Config.publish/0` (or per-entity) pushes central → all tenants (an Oban job or
  a `Release`-callable command for prod).

## Open questions (settle during planning)

1. **Override representation:** a per-tenant "is_overridden" flag on the copied row, vs. a
   separate overrides table. (Leaning: a flag — publish skips rows a tenant marked overridden.)
2. **Publish conflict policy:** overwrite everything vs. skip tenant-overridden rows
   (preferred), and whether publish is all-tenants or selectable.
3. **Editing surface:** an operator UI for central config is a later slice; initially edit
   via console/seed + `publish`.

## Out of scope (for the first cut)
- A config-editing UI.
- Versioned publish history (mega-prompts already carry versioning; reuse later).
- Changing the per-tenant customer-data model (unchanged).
