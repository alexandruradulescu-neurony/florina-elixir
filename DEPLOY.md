# Deploying to Railway

This app deploys as a standard Phoenix release via the `Dockerfile` in this repo.
Railway auto-detects the Dockerfile and builds it.

## What this deploy is

A **standalone** instance of the Phoenix app with its own PostgreSQL database. Each
tenant is isolated by a Postgres **schema** (`tenant_<id>`) on that single database; the
control-plane schema holds the tenant registry, operator admins, and canonical config.
This is a self-contained codebase — it does **not** connect to the live Django app at
runtime.

## One-time Railway setup

1. **Source:** this GitHub repo (deploys from `main`).
2. **PostgreSQL:** add the Railway Postgres plugin (done).
3. **Volume:** **not needed** — the app stores nothing on local disk; all data is in Postgres.
4. **Environment variables** (app service → Variables):

   | Variable | Value |
   |---|---|
   | `DATABASE_URL` | `${{Postgres.DATABASE_URL}}` (reference the Postgres service) |
   | `SECRET_KEY_BASE` | a 64+ char random key — generate with `mix phx.gen.secret` |
   | `PHX_HOST` | your public domain, e.g. `florina-production.up.railway.app` |
   | `PHX_SERVER` | `true` |
   | `ELEVENLABS_WEBHOOK_SECRET` | the `wsec_…` value (from the team `.env`) |
   | `FIELD_ENCRYPTION_KEY` | base64 32-byte key for at-rest encryption (OAuth + CRM tokens) — **required**: the app refuses to boot in prod without it |
   | `ADMIN_EMAIL` / `ADMIN_PASSWORD` | seeds the first operator-admin at boot if none exists (optional) |
   | `ANTHROPIC_API_KEY` | for the live agent chat (`/chat`); without it the app still boots but `/chat` shows an error |

   `PORT` is injected by Railway automatically — do not set it.

5. **Run migrations on deploy:** set the deploy / pre-deploy command to:

   ```
   /app/bin/migrate
   ```

   It creates the tables (Oban jobs + the call table) on first deploy. Safe to re-run.

6. **Public domain:** Settings → Networking → Generate Domain, then put it in `PHX_HOST`.
7. **Health check path:** `/healthz`.

## After it's live

- Point the ElevenLabs webhook URL to `https://<your-domain>/t/<tenant-slug>/webhooks/elevenlabs`
  (the webhook route is tenant-scoped), with the matching `ELEVENLABS_WEBHOOK_SECRET` set.
- (Later) Twilio → `https://<your-domain>/webhooks/twilio` once that slice ships.

## Optional local sanity check (build the production release)

```bash
MIX_ENV=prod mix release
SECRET_KEY_BASE=$(mix phx.gen.secret) PHX_SERVER=true \
  DATABASE_URL=ecto://alex@localhost/florina_dev \
  _build/prod/rel/florina/bin/server
```

## Multi-tenant foundation (local)

Each customer's data lives in its own Postgres **schema** (`tenant_<id>`) on the single
shared database, selected per request/job via the Ecto query prefix.

- Tenant is resolved from the **URL path** (`/t/:tenant_slug/...`), with subdomain as a fallback.
- The control-plane schema (the main app DB) holds a `tenants` registry.
- Set up two local demo tenants: `mix florina.tenants.setup`
- See it work:
  - `http://localhost:4000/t/acme/whoami` vs `http://localhost:4000/t/globex/whoami`
  - Calls dashboard: `http://localhost:4000/t/acme/calls`
  - ElevenLabs webhook: `POST http://localhost:4000/t/acme/webhooks/elevenlabs`

Path-based routing works on the default Railway domain with no custom domain needed.
Subdomain resolution (`acme.localhost`) remains supported as a fallback for future
custom-domain setups.
