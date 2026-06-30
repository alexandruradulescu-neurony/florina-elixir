# Florina — Elixir / Phoenix / Oban

The **Elixir port** of the Florina sales-assistant app (Track 2). This is a separate,
isolated codebase from the live Django app. Its purpose is to gradually take over
parts of the product using Elixir, the Phoenix web framework, and the Oban
background-job system.

## Approach

We follow a **strangler-fig** strategy: grow this new system alongside the existing
Django app, one slice at a time, rather than rewriting everything at once. The first
real slice to move here will be the **real-time features** (voice calls + the live
agent chat), where Elixir's strengths matter most.

Each customer ("tenant") is isolated using a dedicated **Postgres schema**
(`tenant_<id>`) on a single shared database, selected per request/job via the Ecto
query prefix. A central "control-plane" schema holds the tenant registry, operator
admins, and the canonical configuration published down to tenants. See the design specs:

- [Elixir / Phoenix / Oban port (Track 2)](docs/superpowers/specs/2026-06-24-elixir-phoenix-port-design.md)
- [Multitenancy — schema-per-tenant design (Track 1)](docs/superpowers/specs/2026-06-24-multitenancy-database-per-tenant-design.md)

## Current status

Built on:

- Phoenix 1.8 (with LiveView) on the Bandit web server
- Oban for background jobs (Postgres-backed)
- PostgreSQL via Ecto, with schema-per-tenant isolation (see above)

The multitenancy plumbing, the voice-call pipeline, the live agent chat, agent SSO
(Google/Microsoft), calendar sync, and the manager/agent prompt-control surface are all
implemented. See `docs/APPLICATION-SPEC.md` for the architecture.

## Running it locally

Requires Elixir, Erlang/OTP, and a running PostgreSQL. The database connection is set
in `config/dev.exs` (defaults to a local trusted Postgres connection).

```bash
mix setup          # install deps, create + migrate the database, build assets
mix phx.server     # start the app at http://localhost:4000
```

To confirm background jobs work, enqueue the example worker from an IEx session:

```bash
iex -S mix
iex> Oban.insert(Florina.Workers.HelloWorker.new(%{hello: "world"}))
```

The job's `state` moves from `available` to `completed` once Oban processes it.

## Conventions

- **Tests are kept local only** and are not committed to GitHub (see `.gitignore`).
- `AGENTS.md` holds guidance for AI coding tools working in this repo.
