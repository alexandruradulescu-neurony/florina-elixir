# Elixir / Phoenix / Oban Port (Track 2)

**Date:** 2026-06-24
**Status:** Draft for review
**Repo:** **A new, separate GitHub repository** (NOT the live `neurony/florina` repo)
**Relationship:** Must honor the tenant-isolation contract defined in [2026-06-24-multitenancy-database-per-tenant-design.md](2026-06-24-multitenancy-database-per-tenant-design.md).

---

## Summary (plain English)

Gradually move the application onto Elixir, using the Phoenix web framework and the Oban background-job system. Rather than rebuilding everything at once, start by lifting only the **real-time slice** (voice calls + the live agent chat) — the part that genuinely benefits from Elixir — into a new Phoenix app that runs alongside the existing Django app and shares its data. Expand further only if it proves out.

This is a strategic, long-term bet on its own timeline. **It must never block or endanger the multitenancy work or the live app.**

## Why this matters / drivers

1. **Real-time & concurrency** — voice calls and the live agent chat require holding many simultaneous live connections, which is the single biggest strength of the Elixir/Phoenix runtime and is awkward on the current stack. This is the strongest, most defensible technical reason.
2. **Long-term bet** — a strategic choice on language, hiring, and maintainability. Discretionary on timing, which is exactly why it must be de-risked rather than committed to all at once.

## Approach — decision

**Strangler-fig (incremental), not a big-bang rewrite.**

| Approach | Pros | Cons | Verdict |
|---|---|---|---|
| Big-bang full port | One clean uniform codebase | Months reproducing working features for zero new value; live app moves underneath; high risk of never catching up; bets the business on a new-language rewrite | ❌ Rejected |
| **Strangler-fig** | Real-time benefit first & fastest; de-risks the bet (team learns on a bounded, high-value slice); live app stays safe; reversible | Runs two apps over one database for a while (needs discipline) | ✅ **Chosen** |

## Component mapping (current → target)

| Current (Django) | Target (Elixir) | Notes |
|---|---|---|
| Django web framework | **Phoenix** | Phoenix Channels / LiveView handle the real-time slice |
| Background jobs | **Oban** | Robust, database-backed job processing |
| Voice + live agent chat | **Phoenix (first slice to move)** | Highest payoff for Elixir's concurrency model |
| Post-call analysis, prompt assembly, methodology system, PDF, CRUD | **Stay in Django (for now)** | No concurrency benefit; migrate later only if justified |

## Sequencing & relationship to Track 1

- A **small throwaway Phoenix spike** to learn the language and validate the real-time approach is fine **anytime**.
- The **real extraction** of the voice/chat slice should begin **after Track 1's tenant-isolation model is designed**, because every real-time connection will eventually need to know which tenant it belongs to. Building the slice against an undefined tenancy contract would create rework.
- During the strangler phase, the Phoenix app connects to the **same databases** as Django and must respect the **database-per-tenant** routing (Elixir's Ecto supports dynamic, per-tenant database connections, so the model maps cleanly).

## High-level architecture (strangler phase)

```
                ┌───────────────────────────┐
   Live traffic │  Existing Django app      │  (all non-real-time features)
   ────────────▶│  (this repo, live)        │
                └─────────────┬─────────────┘
                              │  shared, per-tenant databases
                ┌─────────────┴─────────────┐
   Real-time    │  New Phoenix app          │  (voice + live agent chat)
   ────────────▶│  (new repo)               │  Oban for background jobs
                └───────────────────────────┘
```

A routing layer (reverse proxy or gateway) sends real-time endpoints to Phoenix and everything else to Django.

## Open decisions (for when this track is specced in detail)

1. **Exact first slice boundary** — confirm precisely which endpoints/flows constitute "voice + live agent chat" and where the seam with Django sits.
2. **Routing mechanism** — how requests are split between Django and Phoenix (reverse proxy paths, subdomain, gateway).
3. **Shared-data access pattern** — Phoenix reading/writing the same per-tenant databases directly vs. talking to Django via an internal API. Direct DB access is simpler for the real-time slice; an API boundary is cleaner long-term.
4. **CI/CD for the new repo** — its own pipeline, deliberately independent of florina's auto-deploy.

## Risks

- **Rewrite never finishes / loses the race with the live app** — mitigated by strangler-fig: each slice delivers value independently; no all-or-nothing cutover.
- **Team Elixir inexperience** — mitigated by starting on one bounded, high-payoff slice (learn before expanding).
- **Two-systems complexity over one database** — accepted for the transition; the tenancy contract from Track 1 keeps data access consistent across both.
- **Scope creep into a full rewrite before the slice proves out** — guard explicitly; expansion is a separate decision after the first slice ships.

## Out of scope

- Multitenancy design itself (Track 1 owns it; this track consumes the contract).
- Any change to the live Django app's deployment.
- A committed timeline for full migration — expansion past the first slice is re-decided after it proves out.
