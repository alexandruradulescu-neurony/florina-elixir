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

This app must eventually honor the **database-per-tenant** isolation model defined for
the live app. See the design specs:

- [Elixir / Phoenix / Oban port (Track 2)](docs/superpowers/specs/2026-06-24-elixir-phoenix-port-design.md)
- [Multitenancy — database-per-tenant (Track 1)](docs/superpowers/specs/2026-06-24-multitenancy-database-per-tenant-design.md)

## Current status: runnable skeleton

This repository currently contains a **clean, runnable foundation only**:

- Phoenix 1.8 (with LiveView) on the Bandit web server
- Oban wired up for background jobs (Postgres-backed), with an example worker
- PostgreSQL via Ecto

Not yet built, on purpose: the voice/chat slice and any multitenancy plumbing. Those
come next, per the specs above.

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
